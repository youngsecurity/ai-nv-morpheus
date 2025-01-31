/*
 * SPDX-FileCopyrightText: Copyright (c) 2022-2024, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

#include "morpheus/doca/doca_source.hpp"

#include <mrc/segment/builder.hpp>  // IWYU pragma: keep
#include <mrc/segment/object.hpp>
#include <pybind11/attr.h>
#include <pybind11/pybind11.h>  // for str_attr_accessor
#include <pymrc/utils.hpp>

#include <memory>

namespace morpheus {

namespace py = pybind11;

// Define the pybind11 module m.
PYBIND11_MODULE(doca, m)
{
    mrc::pymrc::import(m, "morpheus._lib.messages");

    py::class_<mrc::segment::Object<DocaSourceStage>,
               mrc::segment::ObjectProperties,
               std::shared_ptr<mrc::segment::Object<DocaSourceStage>>>(m, "DocaSourceStage", py::multiple_inheritance())
        .def(py::init<>(&DocaSourceStageInterfaceProxy::init),
             py::arg("builder"),
             py::arg("name"),
             py::arg("nic_pci_address"),
             py::arg("gpu_pci_address"),
             py::arg("traffic_type"));
}

}  // namespace morpheus
