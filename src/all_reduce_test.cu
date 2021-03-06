/*************************************************************************
 * Copyright (c) 2015, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ************************************************************************/

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "nccl.h"
#include "test_utilities.h"
#include <nvToolsExt.h>

int csv = false;

template<typename T>
void RunTest(T** sendbuff, T** recvbuff, const int N, const ncclDataType_t type,
    const ncclRedOp_t op, ncclComm_t* comms, const std::vector<int>& dList) {
  // initialize data
  T* buffer = (T*)malloc(N * sizeof(T));
  T* result = (T*)malloc(N * sizeof(T));
  memset(buffer, 0, N * sizeof(T));
  memset(result, 0, N * sizeof(T));

  int nDev = 0;
  ncclCommCount(comms[0], &nDev);
  cudaStream_t* s = (cudaStream_t*)malloc(sizeof(cudaStream_t)*nDev);
  
  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamCreate(s+i));
    CUDACHECK(cudaMemset(recvbuff[i], 0, N * sizeof(T)));
    Randomize(sendbuff[i], N, i);
    if(i == 0) {
      CUDACHECK(cudaMemcpy(result, sendbuff[i], N*sizeof(T), cudaMemcpyDeviceToHost));
    } else {
      Accumulate<T>(result, sendbuff[i], N, op);
    }
  }

  // warm up GPU
  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    ncclAllReduce((const void*)sendbuff[i], (void*)recvbuff[i], std::min(N, 1024 * 1024), type, op, comms[i], s[i]);
  }

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamSynchronize(s[i]));
  }

//  for (int n = 0; n <= N; n = (n > 0) ? n << 1 : 1)
  {
    int n = N;
    printf((csv) ? "%i,%i,%s,%s," : "%12i  %12i  %6s  %6s",
        (int) (n * sizeof(T)), n, TypeName(type).c_str(),
        OperationName(op).c_str());

    // do out-of-place reduction first
    nvtxRangePushA("out of place");
    auto start = std::chrono::high_resolution_clock::now();
    //for (int i=0; i<100; i++) {
      for (int i = 0; i < nDev; ++i) {
        CUDACHECK(cudaSetDevice(dList[i]));
        ncclAllReduce((const void*)sendbuff[i], (void*)recvbuff[i], n, type, op,
            comms[i], s[i]);
      }
    //}

    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      CUDACHECK(cudaStreamSynchronize(s[i]));
    }

    auto stop = std::chrono::high_resolution_clock::now();
    nvtxRangePop();

    nvtxRangePushA("out of place bookkeeping");
    double elapsedSec =
        std::chrono::duration_cast<std::chrono::duration<double>>(
            stop - start).count(); // / 100.0;
    double algbw = (double)(n * sizeof(T)) / 1.0E9 / elapsedSec;
    double busbw = algbw * (double)(2 * nDev - 2) / (double)nDev;

    double maxDelta = 0.0;
    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      double tmpDelta = CheckDelta<T>(recvbuff[i], result, N);
      maxDelta = std::max(tmpDelta, maxDelta);
    }

    printf((csv)?"%f,%f,%f,%le,":"  %7.3f  %5.2f  %5.2f  %7.0le",
        elapsedSec * 1.0E3, algbw, busbw, maxDelta);

    nvtxRangePop();
  }


//  for (int n = 0; n <= N; n = (n > 0) ? n << 1 : 1)
  {
    int n = N;
    // now do in-place reduction
    nvtxRangePushA("in place");
    auto start = std::chrono::high_resolution_clock::now();
    //for (int i=0; i<100; i++) {
      for (int i = 0; i < nDev; ++i) {
        CUDACHECK(cudaSetDevice(dList[i]));
        ncclAllReduce((const void*)sendbuff[i], (void*)sendbuff[i], n, type, op,
            comms[i], s[i]);
      }
    //}

    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      CUDACHECK(cudaStreamSynchronize(s[i]));
    }

    auto stop = std::chrono::high_resolution_clock::now();
    nvtxRangePop();

    nvtxRangePushA("in place bookkeeping");
    double elapsedSec =
        std::chrono::duration_cast<std::chrono::duration<double>>(
            stop - start).count(); // / 100.0;
    double algbw = (double)(n * sizeof(T)) / 1.0E9 / elapsedSec;
    double busbw = algbw * (double)(2 * nDev - 2) / (double)nDev;

    double maxDelta = 0.0;
    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      double tmpDelta = CheckDelta<T>(sendbuff[i], result, N);
      maxDelta = std::max(tmpDelta, maxDelta);
    }

    printf((csv)?"%f,%f,%f,%le,":"  %7.3f  %5.2f  %5.2f  %7.0le\n",
        elapsedSec * 1.0E3, algbw, busbw, maxDelta);

    nvtxRangePop();
  }

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamDestroy(s[i]));
  }
  free(s);
  free(buffer);
  free(result);
}

template<typename T>
void RunTests(const int N, const ncclDataType_t type, ncclComm_t* comms,
    const std::vector<int>& dList) {
  int nDev = 0;
  ncclCommCount(comms[0], &nDev);
  T** sendbuff = (T**)malloc(nDev * sizeof(T*));
  T** recvbuff = (T**)malloc(nDev * sizeof(T*));

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaMalloc(sendbuff + i, N * sizeof(T)));
    CUDACHECK(cudaMalloc(recvbuff + i, N * sizeof(T)));
  }

  for (ncclRedOp_t op : { ncclSum, ncclProd, ncclMax, ncclMin }) {
//  for (ncclRedOp_t op : { ncclSum }) {
    RunTest<T>(sendbuff, recvbuff, N, type, op, comms, dList);
  }

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaFree(sendbuff[i]));
    CUDACHECK(cudaFree(recvbuff[i]));
  }

  free(sendbuff);
  free(recvbuff);
}

void usage() {
  printf("Tests nccl AllReduce with user supplied arguments.\n"
      "    Usage: all_reduce_test <data size in bytes> [number of GPUs] "
      "[GPU 0] [GPU 1] ...\n\n");
}

int main(int argc, char* argv[]) {
  int nVis = 0;
  CUDACHECK(cudaGetDeviceCount(&nVis));

  int N = 0;
  if (argc > 1) {
    int t = sscanf(argv[1], "%d", &N);
    if (t == 0) {
      printf("Error: %s is not an integer!\n\n", argv[1]);
      usage();
      exit(EXIT_FAILURE);
    }
  } else {
    printf("Error: must specify at least data size in bytes!\n\n");
    usage();
    exit(EXIT_FAILURE);
  }

  int nDev = nVis;
  if (argc > 2) {
    int t = sscanf(argv[2], "%d", &nDev);
    if (t == 0) {
      printf("Error: %s is not an integer!\n\n", argv[1]);
      usage();
      exit(EXIT_FAILURE);
    }
  }
  std::vector<int> dList(nDev);
  for (int i = 0; i < nDev; ++i)
    dList[i] = i % nVis;

  if (argc > 3) {
    if (argc - 3 != nDev) {
      printf("Error: insufficient number of GPUs in list\n\n");
      usage();
      exit(EXIT_FAILURE);
    }

    for (int i = 0; i < nDev; ++i) {
      int t = sscanf(argv[3 + i], "%d", dList.data() + i);
      if (t == 0) {
        printf("Error: %s is not an integer!\n\n", argv[2 + i]);
        usage();
        exit(EXIT_FAILURE);
      }
    }
  }

  ncclComm_t* comms = (ncclComm_t*)malloc(sizeof(ncclComm_t)*nDev);
  ncclCommInitAll(comms, nDev, dList.data());

  if (!csv) {
    printf("# Using devices\n");
    for (int g = 0; g < nDev; ++g) {
      int cudaDev;
      int rank;
      cudaDeviceProp prop;
      ncclCommCuDevice(comms[g], &cudaDev);
      ncclCommUserRank(comms[g], &rank);
      CUDACHECK(cudaGetDeviceProperties(&prop, cudaDev));
      printf("#   Rank %2d uses device %2d [0x%02x] %s\n", rank, cudaDev,
          prop.pciBusID, prop.name);
    }
    printf("\n");

    printf("# %10s  %12s  %6s  %6s        out-of-place                    in-place\n", "", "", "", "");
    printf("# %10s  %12s  %6s  %6s  %7s  %5s  %5s  %7s  %7s  %5s  %5s  %7s\n", "bytes", "N", "type", "op",
               "time", "algbw", "busbw", "res", "time", "algbw", "busbw", "res");
  }
  else {
    printf("B,N,type,op,oop_time,oop_algbw,oop_busbw,oop_res,ip_time,ip_algbw,ip_busbw,ip_res\n");
  }

  RunTests<char>(N / sizeof(char), ncclChar, comms, dList);
  RunTests<int>(N / sizeof(int), ncclInt, comms, dList);
#if CUDART_VERSION >= 7050
  RunTests<half>(N / sizeof(half), ncclHalf, comms, dList);
#endif
  RunTests<float>(N / sizeof(float), ncclFloat, comms, dList);
  RunTests<double>(N / sizeof(double), ncclDouble, comms, dList);

  printf("\n");

  for(int i=0; i<nDev; ++i)
    ncclCommDestroy(comms[i]);
  free(comms);

  exit(EXIT_SUCCESS);
}

