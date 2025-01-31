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

#include "morpheus/doca/common.hpp"

#include "morpheus/utilities/error.hpp"

#include <cub/cub.cuh>
#include <cuda/std/chrono>
#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/strings/detail/strings_children.cuh>
#include <cudf/strings/detail/utilities.cuh>
#include <cudf/strings/detail/utilities.hpp>
#include <doca_eth_rxq.h>
#include <doca_gpunetio.h>
#include <doca_gpunetio_dev_buf.cuh>
#include <doca_gpunetio_dev_eth_rxq.cuh>
#include <doca_gpunetio_dev_sem.cuh>
#include <rmm/exec_policy.hpp>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_tcp.h>
#include <stdio.h>
#include <thrust/gather.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>

#include <memory>

#define ETHER_ADDR_LEN  6 /**< Length of Ethernet address. */

#define BYTE_SWAP16(v) \
    ((((uint16_t)(v) & UINT16_C(0x00ff)) << 8) | (((uint16_t)(v) & UINT16_C(0xff00)) >> 8))

#define TCP_PROTOCOL_ID 0x6
#define UDP_PROTOCOL_ID 0x11
#define TIMEOUT_NS 500000 //500us

enum tcp_flags {
    TCP_FLAG_FIN = (1 << 0),
    /* set tcp packet with Fin flag */
    TCP_FLAG_SYN = (1 << 1),
    /* set tcp packet with Syn flag */
    TCP_FLAG_RST = (1 << 2),
    /* set tcp packet with Rst flag */
    TCP_FLAG_PSH = (1 << 3),
    /* set tcp packet with Psh flag */
    TCP_FLAG_ACK = (1 << 4),
    /* set tcp packet with Ack flag */
    TCP_FLAG_URG = (1 << 5),
    /* set tcp packet with Urg flag */
    TCP_FLAG_ECE = (1 << 6),
    /* set tcp packet with ECE flag */
    TCP_FLAG_CWR = (1 << 7),
    /* set tcp packet with CQE flag */
};

struct ether_hdr {
    uint8_t d_addr_bytes[ETHER_ADDR_LEN];	/* Destination addr bytes in tx order */
    uint8_t s_addr_bytes[ETHER_ADDR_LEN];	/* Source addr bytes in tx order */
    uint16_t ether_type;			/* Frame type */
} __attribute__((__packed__));

struct ipv4_hdr {
    uint8_t version_ihl;		/* version and header length */
    uint8_t  type_of_service;	/* type of service */
    uint16_t total_length;		/* length of packet */
    uint16_t packet_id;		/* packet ID */
    uint16_t fragment_offset;	/* fragmentation offset */
    uint8_t  time_to_live;		/* time to live */
    uint8_t  next_proto_id;		/* protocol ID */
    uint16_t hdr_checksum;		/* header checksum */
    uint32_t src_addr;		/* source address */
    uint32_t dst_addr;		/* destination address */
} __attribute__((__packed__));

struct tcp_hdr {
    uint16_t src_port;	/* TCP source port */
    uint16_t dst_port;	/* TCP destination port */
    uint32_t sent_seq;	/* TX data sequence number */
    uint32_t recv_ack;	/* RX data acknowledgment sequence number */
    uint8_t dt_off;		/* Data offset */
    uint8_t tcp_flags;	/* TCP flags */
    uint16_t rx_win;	/* RX flow control window */
    uint16_t cksum;		/* TCP checksum */
    uint16_t tcp_urp;	/* TCP urgent pointer, if any */
} __attribute__((__packed__));

struct eth_ip_tcp_hdr {
    struct ether_hdr l2_hdr;	/* Ethernet header */
    struct ipv4_hdr l3_hdr;		/* IP header */
    struct tcp_hdr l4_hdr;		/* TCP header */
} __attribute__((__packed__));

struct udp_hdr {
    uint16_t src_port;	/* UDP source port */
    uint16_t dst_port;	/* UDP destination port */
    uint16_t dgram_len;	/* UDP datagram length */
    uint16_t dgram_cksum;	/* UDP datagram checksum */
} __attribute__((__packed__));

struct eth_ip_udp_hdr {
    struct ether_hdr l2_hdr;	/* Ethernet header */
    struct ipv4_hdr l3_hdr;		/* IP header */
    struct udp_hdr l4_hdr;		/* UDP header */
} __attribute__((__packed__));

__device__ __inline__ int
raw_to_tcp(const uintptr_t buf_addr, struct eth_ip_tcp_hdr **hdr, uint8_t **packet_data)
{
    (*hdr) = (struct eth_ip_tcp_hdr *) buf_addr;
    (*packet_data) = (uint8_t *) (buf_addr + sizeof(struct ether_hdr) + sizeof(struct ipv4_hdr) + (((*hdr)->l4_hdr.dt_off >> 4) * sizeof(int)));

    return 0;
}

__device__ __inline__ int
raw_to_udp(const uintptr_t buf_addr, struct eth_ip_udp_hdr **hdr, uint8_t **packet_data)
{
    (*hdr) = (struct eth_ip_udp_hdr *) buf_addr;
    (*packet_data) = (uint8_t *) (buf_addr + sizeof(struct eth_ip_udp_hdr));

    return 0;
}

__device__ __forceinline__ uint8_t
gpu_ipv4_hdr_len(const struct ipv4_hdr& packet_l3)
{
    return (uint8_t)((packet_l3.version_ihl & RTE_IPV4_HDR_IHL_MASK) * RTE_IPV4_IHL_MULTIPLIER);
};

__device__ __forceinline__ uint32_t
get_packet_size(ipv4_hdr& packet_l3)
{
    return static_cast<int32_t>(BYTE_SWAP16(packet_l3.total_length));
}

__device__ __forceinline__ int32_t
get_payload_tcp_size(ipv4_hdr& packet_l3, tcp_hdr& packet_l4)
{
    auto packet_size       = get_packet_size(packet_l3);
    auto ip_header_length  = gpu_ipv4_hdr_len(packet_l3);
    auto tcp_header_length = static_cast<int32_t>(packet_l4.dt_off >> 4) * sizeof(int32_t);
    auto payload_size      = packet_size - ip_header_length - tcp_header_length;

    return payload_size;
}

__device__ __forceinline__ int32_t
get_payload_udp_size(ipv4_hdr& packet_l3, udp_hdr& packet_l4)
{
    auto packet_size       = get_packet_size(packet_l3);
    auto ip_header_length  = gpu_ipv4_hdr_len(packet_l3);
    auto payload_size      = packet_size - ip_header_length - sizeof(struct udp_hdr);

    return payload_size;
}

__device__ char to_hex_16(uint8_t value)
{
    return "0123456789ABCDEF"[value];
}

__device__ int64_t mac_bytes_to_int64(uint8_t* mac)
{
    return static_cast<uint64_t>(mac[0]) << 40
        | static_cast<uint64_t>(mac[1]) << 32
        | static_cast<uint32_t>(mac[2]) << 24
        | static_cast<uint32_t>(mac[3]) << 16
        | static_cast<uint32_t>(mac[4]) << 8
        | static_cast<uint32_t>(mac[5]);
}

__device__ int64_t mac_int64_to_chars(int64_t mac, char* out)
{
    uint8_t mac_0 = (mac >> 40) & (0xFF);
    out[0]  = to_hex_16(mac_0 / 16);
    out[1]  = to_hex_16(mac_0 % 16);
    out[2]  = ':';

    uint8_t mac_1 = (mac >> 32) & (0xFF);
    out[3]  = to_hex_16(mac_1 / 16);
    out[4]  = to_hex_16(mac_1 % 16);
    out[5]  = ':';

    uint8_t mac_2 = (mac >> 24) & (0xFF);
    out[6]  = to_hex_16(mac_2 / 16);
    out[7]  = to_hex_16(mac_2 % 16);
    out[8]  = ':';

    uint8_t mac_3 = (mac >> 16) & (0xFF);
    out[9]  = to_hex_16(mac_3 / 16);
    out[10] = to_hex_16(mac_3 % 16);
    out[11] = ':';

    uint8_t mac_4 = (mac >> 8) & (0xFF);
    out[12] = to_hex_16(mac_4 / 16);
    out[13] = to_hex_16(mac_4 % 16);
    out[14] = ':';

    uint8_t mac_5 = (mac >> 0) & (0xFF);
    out[15] = to_hex_16(mac_5 / 16);
    out[16] = to_hex_16(mac_5 % 16);
}

__device__ uint32_t tcp_parse_timestamp(rte_tcp_hdr const *tcp)
{
    const uint8_t *tcp_opt = (typeof(tcp_opt))tcp + RTE_TCP_MIN_HDR_LEN;
    const uint8_t *tcp_data = (typeof(tcp_data))tcp + static_cast<int32_t>(tcp->dt_off * sizeof(int32_t));

    while (tcp_opt < tcp_data) {
        switch(tcp_opt[0]) {
            case RTE_TCP_OPT_END:
            return 0;
            case RTE_TCP_OPT_NOP:
            tcp_opt++;
            continue;
            case RTE_TCP_OPT_TIMESTAMP:
            return (static_cast<uint32_t>(tcp_opt[2]) << 24)
                | (static_cast<uint32_t>(tcp_opt[3]) << 16)
                | (static_cast<uint32_t>(tcp_opt[4]) << 8)
                | (static_cast<uint32_t>(tcp_opt[5]) << 0);
            default:
            if (tcp_opt[1] == 0) {
                return 0;
            } else {
                tcp_opt += tcp_opt[1];
            }
            continue;
        }
    }

    return 0;
}

#define DEVICE_GET_TIME(globaltimer) asm volatile("mov.u64 %0, %globaltimer;" : "=l"(globaltimer))

__global__ void _packet_receive_kernel(
    doca_gpu_eth_rxq*       rxq,
    doca_gpu_semaphore_gpu* sem,
    uint16_t sem_idx,
    const bool is_tcp,
    uint32_t* exit_condition
)
{
    __shared__ uint32_t packet_count_received;
    __shared__ uint64_t packet_offset_received;
    __shared__ struct packets_info *pkt_info;
    // Specialize BlockReduce for a 1D block of 128 threads of type int
    using BlockReduce = cub::BlockReduce<int32_t, THREADS_PER_BLOCK>;
    // Allocate shared memory for BlockReduce
    __shared__ typename BlockReduce::TempStorage temp_storage;
#if RUN_PERSISTENT
    doca_gpu_semaphore_status sem_status;
#endif
    int32_t _payload_sizes[PACKETS_PER_THREAD];
    int32_t _payload_flags[PACKETS_PER_THREAD];
    doca_gpu_buf *buf_ptr;
    uintptr_t buf_addr;
    doca_error_t doca_ret;
    struct eth_ip_tcp_hdr *hdr_tcp;
    struct eth_ip_udp_hdr *hdr_udp;
    uint8_t *payload;
    // unsigned long long rx_start = 0, rx_stop = 0, pkt_proc = 0, reduce_stop =0, reduce_start = 0;

    // IP address conversion
    auto ip_to_int64 = []__device__(auto address){
    return (address & 0x000000ff) << 24
            | (address & 0x0000ff00) << 8
            | (address & 0x00ff0000) >> 8
            | (address & 0xff000000) >> 24;
    };

    //Initial semaphore index 0, assume it's free!
    doca_ret = doca_gpu_dev_semaphore_get_custom_info_addr(sem, sem_idx, (void **)&pkt_info);
    if (doca_ret != DOCA_SUCCESS) {
        printf("Error %d doca_gpu_dev_semaphore_get_custom_info_addr\n", doca_ret);
        DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
        return;
    }

    if (threadIdx.x == 0) {
        DOCA_GPUNETIO_VOLATILE(pkt_info->packet_count_out) = 0;
        DOCA_GPUNETIO_VOLATILE(pkt_info->payload_size_total_out) = 0;
        DOCA_GPUNETIO_VOLATILE(packet_count_received) = 0;
    }
    __syncthreads();

    // do {
        // if (threadIdx.x == 0) DEVICE_GET_TIME(rx_start);
        doca_ret = doca_gpu_dev_eth_rxq_receive_block(rxq, PACKETS_PER_BLOCK, PACKET_RX_TIMEOUT_NS, &packet_count_received, &packet_offset_received);
        if (doca_ret != DOCA_SUCCESS) [[unlikely]] {
            DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
            return;
        }
        __threadfence();
        if (DOCA_GPUNETIO_VOLATILE(packet_count_received) == 0)
            return;

        // if (threadIdx.x == 0)
        //   printf("Block %d sem id %d received %d\n", blockIdx.x, sem_idx, DOCA_GPUNETIO_VOLATILE(packet_count_received));
        // if (threadIdx.x == 0) DEVICE_GET_TIME(rx_stop);

        for (auto i = 0; i < PACKETS_PER_THREAD; i++) {
            auto packet_idx = threadIdx.x * PACKETS_PER_THREAD + i;
            if (packet_idx >= DOCA_GPUNETIO_VOLATILE(packet_count_received)) {
                _payload_sizes[i] = 0;
                _payload_flags[i] = 0;
                continue;
            }

            doca_ret = doca_gpu_dev_eth_rxq_get_buf(rxq, DOCA_GPUNETIO_VOLATILE(packet_offset_received) + packet_idx, &buf_ptr);
            if (doca_ret != DOCA_SUCCESS) [[unlikely]] {
                DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
                return;
            }

            doca_ret = doca_gpu_dev_buf_get_addr(buf_ptr, &buf_addr);
            if (doca_ret != DOCA_SUCCESS) [[unlikely]] {
                DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
                return;
            }

            if (is_tcp) {
                raw_to_tcp(buf_addr, &hdr_tcp, &payload);
                //Payload
                auto payload_size = get_payload_tcp_size(hdr_tcp->l3_hdr, hdr_tcp->l4_hdr);
                for(auto j = 0; j < payload_size; j++)
                    pkt_info->payload_buffer_out[packet_idx * MAX_PKT_SIZE + j] = payload[j];
                _payload_sizes[i] = payload_size;
                _payload_flags[i] = 1;
                pkt_info->payload_sizes_out[packet_idx] = payload_size;
                // mac address
                pkt_info->src_mac_out[packet_idx] = mac_bytes_to_int64(hdr_tcp->l2_hdr.s_addr_bytes);
                pkt_info->dst_mac_out[packet_idx] = mac_bytes_to_int64(hdr_tcp->l2_hdr.d_addr_bytes);
                // ip address
                pkt_info->src_ip_out[packet_idx] = ip_to_int64(hdr_tcp->l3_hdr.src_addr);
                pkt_info->dst_ip_out[packet_idx] = ip_to_int64(hdr_tcp->l3_hdr.dst_addr);
                // ports
                pkt_info->src_port_out[packet_idx] = BYTE_SWAP16(hdr_tcp->l4_hdr.src_port);
                pkt_info->dst_port_out[packet_idx] = BYTE_SWAP16(hdr_tcp->l4_hdr.dst_port);
                // tcp flags
                pkt_info->tcp_flags_out[packet_idx] = static_cast<int32_t> (hdr_tcp->l4_hdr.tcp_flags);
                // frame type
                pkt_info->ether_type_out[packet_idx] = static_cast<int32_t> (hdr_tcp->l2_hdr.ether_type);
                // protocol id
                pkt_info->next_proto_id_out[packet_idx] = static_cast<int32_t> (hdr_tcp->l3_hdr.next_proto_id);
            } else {
                raw_to_udp(buf_addr, &hdr_udp, &payload);
                //Payload
                auto payload_size = get_payload_udp_size(hdr_udp->l3_hdr, hdr_udp->l4_hdr);
                for(auto j = 0; j < payload_size; j++)
                    pkt_info->payload_buffer_out[packet_idx * MAX_PKT_SIZE + j] = payload[j];
                _payload_sizes[i] = payload_size;
                _payload_flags[i] = 1;
                pkt_info->payload_sizes_out[packet_idx] = payload_size;
                // mac address
                pkt_info->src_mac_out[packet_idx] = mac_bytes_to_int64(hdr_udp->l2_hdr.s_addr_bytes);
                pkt_info->dst_mac_out[packet_idx] = mac_bytes_to_int64(hdr_udp->l2_hdr.d_addr_bytes);
                // ip address
                pkt_info->src_ip_out[packet_idx] = ip_to_int64(hdr_udp->l3_hdr.src_addr);
                pkt_info->dst_ip_out[packet_idx] = ip_to_int64(hdr_udp->l3_hdr.dst_addr);
                // ports
                pkt_info->src_port_out[packet_idx] = BYTE_SWAP16(hdr_udp->l4_hdr.src_port);
                pkt_info->dst_port_out[packet_idx] = BYTE_SWAP16(hdr_udp->l4_hdr.dst_port);
                // frame type
                pkt_info->ether_type_out[packet_idx] = static_cast<int32_t> (hdr_udp->l2_hdr.ether_type);
                // protocol id
                pkt_info->next_proto_id_out[packet_idx] = static_cast<int32_t> (hdr_udp->l3_hdr.next_proto_id);
            }

            auto now = cuda::std::chrono::system_clock::now();
            auto now_ms = cuda::std::chrono::time_point_cast<cuda::std::chrono::milliseconds>(now);
            auto epoch = now_ms.time_since_epoch();
            pkt_info->timestamp_out[packet_idx] = epoch.count();
        }

        // if (threadIdx.x == 0) DEVICE_GET_TIME(reduce_start);
        auto payload_size_total = BlockReduce(temp_storage).Sum(_payload_sizes);
        __syncthreads();
        auto packet_count = BlockReduce(temp_storage).Sum(_payload_flags);
        __syncthreads();
        // if (threadIdx.x == 0) DEVICE_GET_TIME(reduce_stop);

        if (threadIdx.x == 0) {
            // DEVICE_GET_TIME(pkt_proc);
            DOCA_GPUNETIO_VOLATILE(pkt_info->packet_count_out) = packet_count;
            DOCA_GPUNETIO_VOLATILE(pkt_info->payload_size_total_out) = payload_size_total;
            // printf("Block %d Update semaphore %d with %d packets %d size\n",
            //   blockIdx.x,
            //   sem_idx, DOCA_GPUNETIO_VOLATILE(pkt_info->packet_count_out), DOCA_GPUNETIO_VOLATILE(pkt_info->payload_size_total_out));
            doca_ret = doca_gpu_dev_semaphore_set_status(sem, sem_idx, DOCA_GPU_SEMAPHORE_STATUS_READY);
            if (doca_ret != DOCA_SUCCESS) {
                printf("Error %d doca_gpu_dev_semaphore_set_status\n", doca_ret);
                DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
                // break;
            }

            // printf("CUDA rx time %ld proc time %ld pkt conv %ld block reduce %ld\n",
            //         rx_stop - rx_start,
            //         pkt_proc - rx_stop,
            //         reduce_start - rx_stop,
            //         reduce_stop - reduce_start);
        }
        __syncthreads();

#if RUN_PERSISTENT
        // sem_idx = (sem_idx+1)%MAX_SEM_X_QUEUE;

        // Get packets' info from next semaphore
        // if (threadIdx.x == 0) {
            // do {
            //     doca_ret = doca_gpu_dev_semaphore_get_status(sem, sem_idx, &sem_status);
            //     if (doca_ret != DOCA_SUCCESS) {
            //         printf("Error %d doca_gpu_dev_semaphore_get_status\n", doca_ret);
            //         DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
            //         break;
            //     }

            //     if (sem_status == DOCA_GPU_SEMAPHORE_STATUS_FREE) {
            //         doca_ret = doca_gpu_dev_semaphore_get_custom_info_addr(sem, sem_idx, (void **)&pkt_info);
            //         if (doca_ret != DOCA_SUCCESS) {
            //             printf("Error %d doca_gpu_dev_semaphore_get_custom_info_addr\n", doca_ret);
            //             DOCA_GPUNETIO_VOLATILE(*exit_condition) = 1;
            //         }

            //         DOCA_GPUNETIO_VOLATILE(pkt_info->packet_count_out) = 0;
            //         DOCA_GPUNETIO_VOLATILE(pkt_info->payload_size_total_out) = 0;
            //         DOCA_GPUNETIO_VOLATILE(packet_count_received) = 0;

            //         break;
            //     }
            // } while (DOCA_GPUNETIO_VOLATILE(*exit_condition) == 0);
          // }
        // __syncthreads();
    // } while (DOCA_GPUNETIO_VOLATILE(*exit_condition) == 0)

  if (threadIdx.x == 0)
    doca_gpu_dev_sem_set_status(sem_in, *sem_idx, DOCA_GPU_SEMAPHORE_STATUS_FREE);
  // __threadfence();
  // __syncthreads();
#endif
}

__global__ void _packet_gather_kernel(
  int32_t  packet_count,
  char*    payload_buffer,
  int32_t* payload_sizes,
  char*    payload_chars_out
)
{
  // Specialize BlockScan for a 1D block of 128 threads of type int
  using BlockScan = cub::BlockScan<int32_t, THREADS_PER_BLOCK>;

  // Allocate shared memory for BlockScan
  __shared__ typename BlockScan::TempStorage temp_storage;

  int32_t payload_capture[PACKETS_PER_THREAD];
  int32_t payload_offsets[PACKETS_PER_THREAD];

  for (auto i = 0; i < PACKETS_PER_THREAD; i++)
  {
    auto packet_idx = threadIdx.x * PACKETS_PER_THREAD + i;

    if (packet_idx >= packet_count) {
      payload_capture[i] = 0;
      payload_offsets[i] = 0;
    } else {
      payload_capture[i] = 1;
      payload_offsets[i] = payload_sizes[packet_idx];
    }
  }

  __syncthreads();

  int32_t data_offsets_agg;
  BlockScan(temp_storage).ExclusiveSum(payload_offsets, payload_offsets, data_offsets_agg);

  __syncthreads();

  int32_t data_capture_agg;
  BlockScan(temp_storage).ExclusiveSum(payload_capture, payload_capture, data_capture_agg);

  __syncthreads();

  for (auto i = 0; i < PACKETS_PER_THREAD; i++)
  {
    auto packet_idx = threadIdx.x * PACKETS_PER_THREAD + i;

    if (packet_idx >= packet_count) {
      continue;
    }

    auto payload_size = payload_sizes[packet_idx];

    for (auto j = 0; j < payload_size; j++)
    {
      auto value = payload_buffer[packet_idx * MAX_PKT_SIZE + j];

      auto payload_chars_out_idx = payload_offsets[i] + j;

      if (payload_chars_out_idx) {
        payload_chars_out[payload_chars_out_idx] = value;
      }
    }
  }
}

namespace morpheus {
namespace doca {

namespace {

struct integers_to_mac_fn {
  cudf::column_device_view const d_column;
  int32_t const* d_offsets;
  char* d_chars;

  __device__ void operator()(cudf::size_type idx)
  {
    int64_t mac_address = d_column.element<int64_t>(idx);
    char* out_ptr       = d_chars + d_offsets[idx];

    mac_int64_to_chars(mac_address, out_ptr);
  }
};

}

std::unique_ptr<cudf::column> integers_to_mac(
  cudf::column_view const& integers,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr
)
{
  CUDF_EXPECTS(integers.type().id() == cudf::type_id::INT64, "Input column must be type_id::INT64 type");
  CUDF_EXPECTS(integers.null_count() == 0, "integers_to_mac does not support null values.");

  cudf::size_type strings_count = integers.size();

  if (strings_count == 0)
  {
    return cudf::make_empty_column(cudf::type_id::STRING);
  }

  auto const_17_itr = thrust::constant_iterator<cudf::size_type>(17);
  auto [offsets_column, bytes] = cudf::detail::make_offsets_child_column(
    const_17_itr,
    const_17_itr + strings_count,
    stream,
    mr
  );

  auto column       = cudf::column_device_view::create(integers, stream);
  auto d_column     = *column;
  auto d_offsets    = offsets_column->view().data<int32_t>();
  auto chars_column = cudf::strings::detail::create_chars_child_column(bytes, stream, mr);
  auto d_chars      = chars_column->mutable_view().data<char>();

  thrust::for_each_n(
    rmm::exec_policy(stream),
    thrust::make_counting_iterator<cudf::size_type>(0),
    strings_count,
    integers_to_mac_fn{d_column, d_offsets, d_chars}
  );

  return cudf::make_strings_column(strings_count,
    std::move(offsets_column),
    std::move(chars_column),
    0,
    {});
}

void cuda_memory_test1()
{
    const unsigned int N = 10485760;
    const unsigned int bytes = N * sizeof(int);
    int *h_a = (int*)malloc(bytes);
    memset(h_a, 0, bytes);
    int *d_a;

    CUDA_TRY(cudaMalloc((int**)&d_a, bytes));
    CUDA_TRY(cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice));
    CUDA_TRY(cudaMemcpy(h_a, d_a, bytes, cudaMemcpyDeviceToHost));

    free(h_a);
    CUDA_TRY(cudaFree(d_a));
}

void cuda_memory_test2()
{
    const unsigned int N = 10485760;
    const unsigned int bytes = N * sizeof(int);
    int *h_a = (int*)malloc(bytes);
    memset(h_a, 0, bytes);
    int *d_a;

    CUDA_TRY(cudaMalloc((int**)&d_a, bytes));
    CUDA_TRY(cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice));
    CUDA_TRY(cudaMemcpy(h_a, d_a, bytes, cudaMemcpyDeviceToHost));

    free(h_a);
    CUDA_TRY(cudaFree(d_a));
}

void packet_receive_kernel(
  doca_gpu_eth_rxq*       rxq,
  doca_gpu_semaphore_gpu* sem,
  uint16_t sem_idx,
  bool is_tcp,
  uint32_t*               exit_condition,
  cudaStream_t            stream
)
{
  _packet_receive_kernel<<<1, THREADS_PER_BLOCK, 0, stream>>>(rxq, sem, sem_idx, is_tcp, exit_condition);
}

std::unique_ptr<cudf::column> gather_payload(
  int32_t      packet_count,
  char*        payload_buffer,
  int32_t*     payload_sizes,
  rmm::cuda_stream_view stream,
  rmm::mr::device_memory_resource* mr)
{
  auto [offsets_column, bytes] = cudf::detail::make_offsets_child_column(
    payload_sizes,
    payload_sizes + packet_count,
    stream,
    mr
  );

  auto chars_column = cudf::strings::detail::create_chars_child_column(bytes, stream, mr);
  auto d_chars      = chars_column->mutable_view().data<char>();

  _packet_gather_kernel<<<1, THREADS_PER_BLOCK, 0, stream>>>(
    packet_count,
    payload_buffer,
    payload_sizes,
    d_chars
  );

  return cudf::make_strings_column(packet_count,
    std::move(offsets_column),
    std::move(chars_column),
    0,
    {});
}

}

}
