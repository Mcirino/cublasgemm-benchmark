#include <unistd.h>
#include <iostream>
#include <stdlib.h>
#include <assert.h>
#include <cuda_runtime.h>
#include <cublas_v2.h>
#include "fp16_conversion.h"

using namespace std;

// #define FP16MM

const char* cublasGetErrorString(cublasStatus_t status)
{
    switch(status)
    {
        case CUBLAS_STATUS_SUCCESS: return "CUBLAS_STATUS_SUCCESS";
        case CUBLAS_STATUS_NOT_INITIALIZED: return "CUBLAS_STATUS_NOT_INITIALIZED";
        case CUBLAS_STATUS_ALLOC_FAILED: return "CUBLAS_STATUS_ALLOC_FAILED";
        case CUBLAS_STATUS_INVALID_VALUE: return "CUBLAS_STATUS_INVALID_VALUE"; 
        case CUBLAS_STATUS_ARCH_MISMATCH: return "CUBLAS_STATUS_ARCH_MISMATCH"; 
        case CUBLAS_STATUS_MAPPING_ERROR: return "CUBLAS_STATUS_MAPPING_ERROR";
        case CUBLAS_STATUS_EXECUTION_FAILED: return "CUBLAS_STATUS_EXECUTION_FAILED"; 
        case CUBLAS_STATUS_INTERNAL_ERROR: return "CUBLAS_STATUS_INTERNAL_ERROR"; 
    }
    return "unknown error";
}

// Convenience function for checking CUDA runtime API results
// can be wrapped around any runtime API call. No-op in release builds.
inline
cudaError_t checkCuda(cudaError_t result)
{
  if (result != cudaSuccess) {
    fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
    assert(result == cudaSuccess);
  }
  return result;
}

inline
cublasStatus_t checkCublas(cublasStatus_t result)
{
  if (result != CUBLAS_STATUS_SUCCESS) {
    fprintf(stderr, "CUDA Runtime Error: %s\n", cublasGetErrorString(result));
    assert(result == CUBLAS_STATUS_SUCCESS);
  }
  return result;
}

// Fill the array A(nr_rows_A, nr_cols_A) with random numbers on CPU
void CPU_fill_rand(double *A, int nr_rows_A, int nr_cols_A) {
	int a=1;

    for(int i = 0; i < nr_rows_A * nr_cols_A; i++){
		A[i] = (double)rand()/(double)(RAND_MAX/a);
	}
}

int main(int argc, char ** argv){


  int min_m_k_n = 64; // min matrix size
  int max_m_k_n = 9600; // max matrix size
  int repeats = 100;
  int verbose = 1;

#ifndef FP16MM
  cout << "\ncublasDgemm test result:\n" << endl;
#else
  cout << "\ncublasHgemm test result:\n" << endl;
#endif
  
  if(verbose) 
    cout << "running with" 
	 << " min_m_k_n: " << min_m_k_n
	 << " max_m_k_n: " << max_m_k_n
	 << " repeats: " << repeats
	 << endl;

  cublasStatus_t stat;
  cublasHandle_t handle;

  checkCublas(cublasCreate(&handle));

  if(verbose) cout << "allocating device variables" << endl;
  
  // Allocate 3 arrays on CPU
  
  double *h_A = (double *)malloc(max_m_k_n * max_m_k_n * sizeof(double));
  double *h_B = (double *)malloc(max_m_k_n * max_m_k_n * sizeof(double));
  double *h_C = (double *)malloc(max_m_k_n * max_m_k_n * sizeof(double));
  
  CPU_fill_rand(h_A, max_m_k_n, max_m_k_n);
  CPU_fill_rand(h_B, max_m_k_n, max_m_k_n);
  CPU_fill_rand(h_C, max_m_k_n, max_m_k_n);

#ifndef FP16MM
    // Allocate 3 arrays on GPU
    double *d_A, *d_B, *d_C;
    checkCuda(cudaMallocManaged(&d_A, max_m_k_n * max_m_k_n * sizeof(double)));
    checkCuda(cudaMallocManaged(&d_B, max_m_k_n * max_m_k_n * sizeof(double)));
    checkCuda(cudaMallocManaged(&d_C, max_m_k_n * max_m_k_n * sizeof(double)));
    
    checkCuda(cudaMemcpy(d_A,h_A,max_m_k_n * max_m_k_n * sizeof(double),cudaMemcpyHostToDevice));
    checkCuda(cudaMemcpy(d_B,h_B,max_m_k_n * max_m_k_n * sizeof(double),cudaMemcpyHostToDevice));
    checkCuda(cudaMemcpy(d_C,h_C,max_m_k_n * max_m_k_n * sizeof(double),cudaMemcpyHostToDevice));
    
    int lda, ldb, ldc, m, n, k;
    const double alf = 1.0f;
    const double bet = 0.0f;
    const double *alpha = &alf;
    const double *beta = &bet;
  
#else
    
  	__half *d_A, *d_B, *d_C;
    checkCuda(cudaMallocManaged(&d_A, max_m_k_n * max_m_k_n * sizeof(__half)));
    checkCuda(cudaMallocManaged(&d_B, max_m_k_n * max_m_k_n * sizeof(__half)));
    checkCuda(cudaMallocManaged(&d_C, max_m_k_n * max_m_k_n * sizeof(__half)));
    
    for (int i = 0; i < max_m_k_n * max_m_k_n; i++) {
      d_A[i] = approx_double_to_half(h_A[i]);
  	  d_B[i] = approx_double_to_half(h_B[i]);
  	  d_C[i] = approx_double_to_half(h_C[i]);
    }
    
    int lda, ldb, ldc, m, n, k;
    const __half alf = approx_double_to_half(1.0);
    const __half bet = approx_double_to_half(0.0);
    const __half *alpha = &alf;
    const __half *beta = &bet;
	
#endif
  
  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  for(int size = min_m_k_n; size <= max_m_k_n; size=size+64){ // step size

    float sum = 0.0;
    for(int rep = 0; rep < repeats; rep++){
      cudaEventRecord(start, 0);
	  m=n=k=size;
	  lda = m;
	  ldb = k;
    ldc = m;
#ifndef FP16MM
  stat = cublasDgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, alpha, d_A, lda, d_B, ldb, beta, d_C, ldc); 
#else
	stat = cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, alpha, d_A, lda, d_B, ldb, beta, d_C, ldc); 
#endif
      cudaEventRecord(stop,0);
      cudaEventSynchronize(stop);
      if(stat != CUBLAS_STATUS_SUCCESS){
	cerr << "cublasDgemmBatched failed" << endl;
	exit(1);
      }
      assert(!cudaGetLastError());
      
      float elapsed;
      cudaEventElapsedTime(&elapsed, start, stop);
      elapsed /= 1000.0f;
      sum += elapsed;
    }
    float time = sum/repeats;
#ifndef FP16MM	
  cout << " matrix (32): " 
#else
  cout << " matrix (16): " 
#endif

<< size << ", ops: " << endl << " average time: " << time << " s "<< endl;
// GFLOPS: (m*n*k*2/time)/1e9
  }

  //Free GPU memory
  cudaFree(d_A);
  cudaFree(d_B);
  cudaFree(d_C);

  // Free CPU memory
  free(h_A);
  free(h_B);
  free(h_C);
      
  return 0;
}
