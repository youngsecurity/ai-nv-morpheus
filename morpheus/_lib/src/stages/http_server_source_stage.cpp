/*
 * SPDX-FileCopyrightText: Copyright (c) 2023-2024, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "morpheus/stages/http_server_source_stage.hpp"

#include <boost/beast/http/status.hpp>        // for int_to_status, status
#include <boost/fiber/channel_op_status.hpp>  // for channel_op_status
#include <cudf/io/json.hpp>                   // for json_reader_options & read_json
#include <glog/logging.h>                     // for CHECK & LOG

#include <exception>  // for std::exception
#include <sstream>    // needed by GLOG
#include <stdexcept>  // for std::runtime_error
#include <thread>     // for std::this_thread::sleep_for
#include <tuple>      // for make_tuple
#include <utility>    // for std::move
// IWYU thinks we need more boost headers than we need as int_to_status is defined in status.hpp
// IWYU pragma: no_include <boost/beast/http.hpp>

namespace morpheus {

class SourceStageStopAfter : public std::exception
{};

// Component public implementations
// ************ HttpServerSourceStage ************* //
HttpServerSourceStage::HttpServerSourceStage(std::string bind_address,
                                             unsigned short port,
                                             std::string endpoint,
                                             std::string method,
                                             unsigned accept_status,
                                             float sleep_time,
                                             long queue_timeout,
                                             std::size_t max_queue_size,
                                             unsigned short num_server_threads,
                                             std::size_t max_payload_size,
                                             std::chrono::seconds request_timeout,
                                             bool lines,
                                             std::size_t stop_after) :
  PythonSource(build()),
  m_sleep_time{sleep_time},
  m_queue_timeout{queue_timeout},
  m_queue{max_queue_size},
  m_stop_after{stop_after},
  m_records_emitted{0}
{
    CHECK(boost::beast::http::int_to_status(accept_status) != boost::beast::http::status::unknown)
        << "Invalid HTTP status code: " << accept_status;

    payload_parse_fn_t parser = [this, accept_status, lines](const std::string& payload) {
        std::unique_ptr<cudf::io::table_with_metadata> table{nullptr};
        try
        {
            cudf::io::source_info source{payload.c_str(), payload.size()};
            auto options = cudf::io::json_reader_options::builder(source).lines(lines);
            table        = std::make_unique<cudf::io::table_with_metadata>(cudf::io::read_json(options.build()));
        } catch (const std::exception& e)
        {
            std::string error_msg = "Error occurred converting HTTP payload to Dataframe";
            LOG(ERROR) << error_msg << ": " << e.what();
            return std::make_tuple(400u, "text/plain", error_msg, nullptr);
        }

        try
        {
            // NOLINTNEXTLINE(clang-diagnostic-unused-value)
            DCHECK_NOTNULL(table);
            auto queue_status = m_queue.push_wait_for(std::move(table), m_queue_timeout);

            if (queue_status == boost::fibers::channel_op_status::success)
            {
                return std::make_tuple(accept_status, "text/plain", std::string(), nullptr);
            }

            std::string error_msg = "HTTP payload queue is ";
            switch (queue_status)
            {
            case boost::fibers::channel_op_status::full:
            case boost::fibers::channel_op_status::timeout: {
                error_msg += "full";
                break;
            }

            case boost::fibers::channel_op_status::closed: {
                error_msg += "closed";
                break;
            }
            default: {
                error_msg += "in an unknown state";
                break;
            }
            }

            return std::make_tuple(503u, "text/plain", std::move(error_msg), nullptr);
        } catch (const std::exception& e)
        {
            std::string error_msg = "Error occurred while pushing payload to queue";
            LOG(ERROR) << error_msg << ": " << e.what();
            return std::make_tuple(500u, "text/plain", error_msg, nullptr);
        }
    };
    m_server = std::make_unique<HttpServer>(std::move(parser),
                                            std::move(bind_address),
                                            port,
                                            std::move(endpoint),
                                            std::move(method),
                                            num_server_threads,
                                            max_payload_size,
                                            request_timeout);
}

HttpServerSourceStage::subscriber_fn_t HttpServerSourceStage::build()
{
    return [this](rxcpp::subscriber<source_type_t> subscriber) -> void {
        try
        {
            m_server->start();
            this->source_generator(subscriber);
        } catch (const SourceStageStopAfter& e)
        {
            DLOG(INFO) << "Completed after emitting " << m_records_emitted << " records";
        } catch (const std::exception& e)
        {
            LOG(ERROR) << "Encountered error while listening for incoming HTTP requests: " << e.what() << std::endl;
            subscriber.on_error(std::make_exception_ptr(e));
            return;
        }
        subscriber.on_completed();
        this->close();
    };
}

void HttpServerSourceStage::source_generator(rxcpp::subscriber<HttpServerSourceStage::source_type_t> subscriber)
{
    // only check if the server is running when the queue is empty, allowing all queued messages to be processed prior
    // to shutting down
    bool server_running = true;
    bool queue_closed   = false;
    while (subscriber.is_subscribed() && server_running && !queue_closed)
    {
        table_t table_ptr{nullptr};
        auto queue_status = m_queue.try_pop(table_ptr);
        if (queue_status == boost::fibers::channel_op_status::success)
        {
            // NOLINTNEXTLINE(clang-diagnostic-unused-value)
            DCHECK_NOTNULL(table_ptr);
            try
            {
                auto message     = MessageMeta::create_from_cpp(std::move(*table_ptr), 0);
                auto num_records = message->count();
                subscriber.on_next(std::move(message));
                m_records_emitted += num_records;
            } catch (const std::exception& e)
            {
                LOG(ERROR) << "Error occurred converting HTTP payload to Dataframe: " << e.what();
            }

            if (m_stop_after > 0 && m_records_emitted >= m_stop_after)
            {
                throw SourceStageStopAfter();
            }
        }
        else if (queue_status == boost::fibers::channel_op_status::empty)
        {
            // if the queue is empty, maybe it's because our server is not running
            server_running = m_server->is_running();

            if (server_running)
            {
                // Sleep when there are no messages
                std::this_thread::sleep_for(m_sleep_time);
            }
        }
        else if (queue_status == boost::fibers::channel_op_status::closed)
        {
            queue_closed = true;
        }
        else
        {
            std::string error_msg{"Unknown queue status: " + std::to_string(static_cast<int>(queue_status))};
            LOG(ERROR) << error_msg;
            throw std::runtime_error(error_msg);
        }
    }
}

void HttpServerSourceStage::close()
{
    if (m_server)
    {
        m_server->stop();  // this is a no-op if the server is not running
        m_server.reset();
    }
    m_queue.close();
}

HttpServerSourceStage::~HttpServerSourceStage()
{
    close();
}

// ************ HttpServerSourceStageInterfaceProxy ************ //
std::shared_ptr<mrc::segment::Object<HttpServerSourceStage>> HttpServerSourceStageInterfaceProxy::init(
    mrc::segment::Builder& builder,
    const std::string& name,
    std::string bind_address,
    unsigned short port,
    std::string endpoint,
    std::string method,
    unsigned accept_status,
    float sleep_time,
    long queue_timeout,
    std::size_t max_queue_size,
    unsigned short num_server_threads,
    std::size_t max_payload_size,
    int64_t request_timeout,
    bool lines,
    std::size_t stop_after)
{
    return builder.construct_object<HttpServerSourceStage>(

        name,
        std::move(bind_address),
        port,
        std::move(endpoint),
        std::move(method),
        accept_status,
        sleep_time,
        queue_timeout,
        max_queue_size,
        num_server_threads,
        max_payload_size,
        std::chrono::seconds(request_timeout),
        lines,
        stop_after);
}
}  // namespace morpheus
