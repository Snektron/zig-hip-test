#include <hip/hip_runtime.h>

constexpr unsigned items_per_thread = 24;
constexpr unsigned block_dim = 256;
constexpr unsigned items_per_block = block_dim * items_per_thread;

extern "C" __global__ void kernel(
    float* values,
    unsigned last_block,
    unsigned valid_in_last_block
) {
    const auto bid = __builtin_amdgcn_workgroup_id_x();
    const auto tid = __builtin_amdgcn_workitem_id_x();
    const auto block_offset = bid * items_per_block;

    float total = 0;

    if (bid == last_block) {
        #pragma unroll
        for (int i = 0; i < items_per_thread; ++i) {
            const auto index = block_dim * i + tid;
            if (index < valid_in_last_block)
                total += values[block_offset + block_dim * i + tid];
        }
    } else {
        #pragma unroll
        for (int i = 0; i < items_per_thread; ++i) {
            total += values[block_offset + block_dim * i + tid];
        }
    }

    __shared__ float shared[block_dim];
    shared[tid] = total;
    __syncthreads();

    #pragma unroll
    for (int i = 1; i < block_dim; i <<= 1) {
        if (tid % (i * 2) == 0) {
            shared[tid] += shared[tid + i];
        }
        __syncthreads();
    }

    if (tid == 0) {
        values[bid] = shared[0];
    }
}
