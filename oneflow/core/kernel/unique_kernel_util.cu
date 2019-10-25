#include "oneflow/core/kernel/unique_kernel_util.h"
#include <cub/cub.cuh>

namespace oneflow {

namespace {

template<typename T>
struct Buffer final {
  T* ptr = nullptr;
  size_t size_in_bytes = 0;
};

int64_t SizeAlign(int64_t size) { return RoundUp(size, kCudaAlignSize); }

template<typename T, typename U>
int64_t GetSortKeySize(int64_t n) {
  return SizeAlign(n * sizeof(T));
}

template<typename T, typename U>
int64_t GetSortValueSize(int64_t n) {
  return SizeAlign(n * sizeof(U));
}

template<typename T, typename U>
int64_t GetCubSortTempStorageSize(int64_t n) {
  size_t cub_sort_temp_store_size = 0;
  CudaCheck(cub::DeviceRadixSort::SortPairs<T, U>(nullptr, cub_sort_temp_store_size, nullptr,
                                                  nullptr, nullptr, nullptr, n));
  CHECK_GE(cub_sort_temp_store_size, 0);
  CHECK_LT(cub_sort_temp_store_size, GetMaxVal<int64_t>());
  return SizeAlign(static_cast<int64_t>(cub_sort_temp_store_size));
}

template<typename T, typename U>
int64_t GetCubRleTempStorageSize(int64_t n) {
  size_t cub_rle_temp_store_size = 0;
  CudaCheck(cub::DeviceRunLengthEncode::Encode<T*, T*, U*, int64_t*>(
      nullptr, cub_rle_temp_store_size, nullptr, nullptr, nullptr, nullptr, n));
  CHECK_GE(cub_rle_temp_store_size, 0);
  CHECK_LT(cub_rle_temp_store_size, GetMaxVal<int64_t>());
  return SizeAlign(static_cast<int64_t>(cub_rle_temp_store_size));
}

template<typename T, typename U>
int64_t GetCubScanTempStorageSize(int64_t n) {
  size_t cub_scan_temp_store_size = 0;
  CudaCheck(cub::DeviceScan::ExclusiveSum<U*, U*>(nullptr, cub_scan_temp_store_size, nullptr,
                                                  nullptr, n));
  CHECK_GE(cub_scan_temp_store_size, 0);
  CHECK_LT(cub_scan_temp_store_size, GetMaxVal<int64_t>());
  return SizeAlign(static_cast<int64_t>(cub_scan_temp_store_size));
}

template<typename T, typename U>
int64_t GetCubTempStorageSize(int64_t n) {
  int64_t cub_temp_storage_size = 0;
  cub_temp_storage_size = std::max(cub_temp_storage_size, GetCubSortTempStorageSize<T, U>(n));
  cub_temp_storage_size = std::max(cub_temp_storage_size, GetCubRleTempStorageSize<T, U>(n));
  cub_temp_storage_size = std::max(cub_temp_storage_size, GetCubScanTempStorageSize<T, U>(n));
  return cub_temp_storage_size;
}

template<typename T>
void AliasPtr(void* origin, int64_t* offset, Buffer<T>* buffer, int64_t size) {
  auto* ptr = reinterpret_cast<unsigned char*>(origin);
  if (buffer != nullptr) {
    buffer->ptr = reinterpret_cast<T*>(ptr + *offset);
    buffer->size_in_bytes = size;
  }
  *offset += size;
}

template<typename T, typename U>
void UniqueAliasWorkspace(DeviceCtx* ctx, int64_t n, void* workspace,
                          int64_t* workspace_size_in_bytes, Buffer<T>* cub_sort_keys_out,
                          Buffer<U>* cub_sort_values_in, Buffer<U>* cub_sort_values_out,
                          Buffer<U>* cub_scan_d_out, Buffer<U>* rle_decode_out,
                          Buffer<void>* cub_temp_storage) {
  int64_t offset = 0;
  AliasPtr(workspace, &offset, cub_sort_keys_out, GetSortKeySize<T, U>(n));
  AliasPtr(workspace, &offset, cub_sort_values_in, GetSortValueSize<T, U>(n));
  AliasPtr(workspace, &offset, cub_sort_values_out, GetSortValueSize<T, U>(n));
  AliasPtr(workspace, &offset, cub_scan_d_out, GetSortValueSize<T, U>(n));
  AliasPtr(workspace, &offset, rle_decode_out, GetSortValueSize<T, U>(n));
  AliasPtr(workspace, &offset, cub_temp_storage, GetCubTempStorageSize<T, U>(n));
  *workspace_size_in_bytes = offset;
}

template<typename T>
__global__ void IotaKernel(int64_t n, T* out) {
  CUDA_1D_KERNEL_LOOP(i, n) { out[i] = static_cast<T>(i); }
}

template<typename T>
__global__ void RleDecodeKernel(const int64_t* n, T* offsets, T* counts, T* out) {
  CUDA_1D_KERNEL_LOOP(i, n) {
    for (int64_t j = offsets[i]; j < offsets[i] + counts[i]; j++) { out[j] = i; }
  }
}

}  // namespace

template<typename T, typename U>
struct UniqueKernelUtil<DeviceType::kGPU, T, U> {
  static void Unique(DeviceCtx* ctx, int64_t n, const T* in, int64_t* num_unique, T* unique_out,
                     U* idx_out, void* workspace, int64_t workspace_size_in_bytes);
  static void GetUniqueWorkspaceSizeInBytes(DeviceCtx* ctx, int64_t n,
                                            int64_t* workspace_size_in_bytes);
};

template<typename T, typename U>
void UniqueKernelUtil<DeviceType::kGPU, T, U>::Unique(DeviceCtx* ctx, int64_t n, const T* in,
                                                      int64_t* num_unique, T* unique_out,
                                                      U* idx_out, void* workspace,
                                                      int64_t workspace_size_in_bytes) {
  int64_t rt_workspace_size;
  Buffer<T> cub_sort_keys_out;
  Buffer<U> cub_sort_values_in_n_cub_rle_counts_out;
  Buffer<U> cub_sort_values_out;
  Buffer<U> cub_scan_d_out;
  Buffer<U> rle_decode_out;
  Buffer<void> cub_temp_storage;
  UniqueAliasWorkspace<T, U>(ctx, n, workspace, &rt_workspace_size, &cub_sort_keys_out,
                             &cub_sort_values_in_n_cub_rle_counts_out, &cub_sort_values_out,
                             &cub_scan_d_out, &rle_decode_out, &cub_temp_storage);
  CHECK_LE(rt_workspace_size, workspace_size_in_bytes);
  IotaKernel<U><<<BlocksNum4ThreadsNum(n), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
      n, cub_sort_values_in_n_cub_rle_counts_out.ptr);
  CudaCheck(cub::DeviceRadixSort::SortPairs<T, U>(
      cub_temp_storage.ptr, cub_temp_storage.size_in_bytes, in, cub_sort_keys_out.ptr,
      cub_sort_values_in_n_cub_rle_counts_out.ptr, cub_sort_values_out.ptr, n, 0, sizeof(T) * 8,
      ctx->cuda_stream()));
  CudaCheck(cub::DeviceRunLengthEncode::Encode<T*, T*, U*, int64_t*>(
      cub_temp_storage.ptr, cub_temp_storage.size_in_bytes, cub_sort_keys_out.ptr, unique_out,
      cub_sort_values_in_n_cub_rle_counts_out.ptr, num_unique, n, ctx->cuda_stream()));
  CudaCheck(cub::DeviceScan::ExclusiveSum<U*, U*>(
      cub_temp_storage.ptr, cub_temp_storage.size_in_bytes,
      cub_sort_values_in_n_cub_rle_counts_out.ptr, cub_scan_d_out.ptr, n, ctx->cuda_stream()));
  RleDecodeKernel<U><<<BlocksNum4ThreadsNum(n), kCudaThreadsNumPerBlock, 0, ctx->cuda_stream()>>>(
      num_unique, cub_scan_d_out.ptr, cub_sort_values_in_n_cub_rle_counts_out.ptr,
      rle_decode_out.ptr);
}

template<typename T, typename U>
void UniqueKernelUtil<DeviceType::kGPU, T, U>::GetUniqueWorkspaceSizeInBytes(
    DeviceCtx* ctx, int64_t n, int64_t* workspace_size_in_bytes) {
  UniqueAliasWorkspace<T, U>(ctx, n, nullptr, workspace_size_in_bytes, nullptr, nullptr, nullptr,
                             nullptr, nullptr, nullptr);
}

#define INSTANTIATE_UNIQUE_KERNEL_UTIL_GPU(k_type_pair, v_type_pair)                \
  template struct UniqueKernelUtil<DeviceType::kGPU, OF_PP_PAIR_FIRST(k_type_pair), \
                                   OF_PP_PAIR_FIRST(v_type_pair)>;
OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(INSTANTIATE_UNIQUE_KERNEL_UTIL_GPU, UNIQUE_KERNEL_KV_DATA_TYPE_SEQ,
                                 UNIQUE_KERNEL_KV_DATA_TYPE_SEQ);
#undef INSTANTIATE_UNIQUE_KERNEL_UTIL_GPU

}  // namespace oneflow