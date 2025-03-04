/* Copyright 2022 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

#ifndef XLA_GPU_PASSES
#define XLA_GPU_PASSES

include "mlir/Pass/PassBase.td"

//===----------------------------------------------------------------------===//
// Auxiliary passes for lowering to XLA Gpu runtime.
//===----------------------------------------------------------------------===//

def ConvertMemrefGetGlobalToArgPass :
    Pass<"xla-memref-get-global-to-arg", "mlir::ModuleOp"> {
  let summary = "Converts memref.get_global corresponding to lmhlo constants";

  let description = [{
    Replaces `memref.get_global` operations corresponding to the lmhlo constant
    arguments (arguments marked with `lmhlo.constant_name` attribute) to use
    the constant arguments directly.

    Once we used global constants for constant folding, we no longer need to
    keep them in the module, because they'll be in the binary constant section
    on the host, and we need them on the device.
  }];

  let constructor = "createConvertMemrefGetGlobalToArgPass()";

  let options = [
    Option<"min_num_elements_", "min-num-elements", "int64_t", /*default=*/"0",
           "Do not convert `memref.get_global` operation if the number of "
           "elements is smaller than the given value.">,
  ];
}

//===----------------------------------------------------------------------===//
// Passes for lowering from the `gpu` dialect.
//===----------------------------------------------------------------------===//

def ConvertGpuToGpuRuntimePass :
    Pass<"xla-gpu-to-gpu-runtime", "mlir::ModuleOp"> {
  let summary = "Converts gpu operations to XLA Gpu runtime custom calls";

  let description = [{
    Converts gpu operations (function launch, memcpy, etc...) to the XLA Gpu
    runtime custom calls.
  }];

  let constructor = "createConvertGpuToGpuRuntimePass()";
}

//===----------------------------------------------------------------------===//
// Passes for lowering from the `lmhlo` dialect.
//===----------------------------------------------------------------------===//

def ConvertLmhloToGpuLaunchPass :
    Pass<"xla-lmhlo-to-gpu-launch", "mlir::ModuleOp"> {
  let summary = "Converts lmhlo fusions to Gpu dialect kernel launch";

  let description = [{
    Converts lmhlo operations that have registered IR emitters (e.g. fusions) to
    Gpu dialect kernel launch operations (and trivial memory operations like
    memcpy or memset). This pass relies on a pre-compiled ThunkSequence with an
    associated device module (PTX and cubin) to find device kernels
    corresponding to lmhlo operation in the input module.

    Created Gpu kernel launch operations can be further lowered to the Gpu
    runtime by the `xla-gpu-to-gpu-runtime` pass.
  }];

  let constructor = "createConvertLmhloToGpuLaunchPass()";
}

def ConvertLmhloToGpuRuntimePass :
    Pass<"xla-lmhlo-to-gpu-runtime", "mlir::ModuleOp"> {
  let summary = "Converts lmhlo operations to XLA Gpu runtime custom calls";

  let description = [{
    Converts lmhlo dialect operations (infeed, outfeed, collectives, etc...) to
    the XLA Gpu runtime custom calls.
  }];

  let constructor = "createConvertLmhloToGpuRuntimePass()";
}

//===----------------------------------------------------------------------===//
// Passes for lowering from the `lmhlo_gpu` dialect.
//===----------------------------------------------------------------------===//

def ConvertLmhloGpuToGpuRuntimePass :
    Pass<"xla-lmhlo-gpu-to-gpu-runtime", "mlir::ModuleOp"> {
  let summary = "Converts lmhlo_gpu operations to XLA Gpu runtime custom calls";

  let description = [{
    Converts lmhlo_gpu dialect operations (gemm, convolution, etc...) to
    the XLA Gpu runtime custom calls.
  }];

  let constructor = "createConvertLmhloGpuToGpuRuntimePass()";
}

//===----------------------------------------------------------------------===//
// XLA runtime performance tracing passes.
//===----------------------------------------------------------------------===//

// TODO(ezhulenev): This pass should be generic for all backends, consider
// moving it to the `transforms/runtime` folder once it will be used by CPU
// compiler.

def AddHloTraceAnnotationsPass :
    Pass<"xla-add-hlo-trace-annotations", "mlir::ModuleOp"> {
  let summary = "Adds HLO trace annotations to the supported operations";

  let description = [{
    Adds HLO trace annotations to the operations that result from compiling
    an input HLO module, e.g. it adds HLO trace annotations to all runtime custom
    calls that are constructed from the corresponding HLO operations.

    Example:

    ```mlir
    call @xla.gpu.gemm(...) : (...) -> memref<?x?xf32>
    ```

    becomes:

    ```mlir
    call @xla.gpu.gemm(...) { rt.trace = #rt.hlo<"gemm.1", "xla_module", 0> }
      : (...) -> memref<?x?xf32>
    ```

    XLA compilation pipeline wraps traced operations into the `rt.trace`
    operation, and eventually lowers them to the tracing API calls.
  }];

  let constructor = "createAddHloTraceAnnotationsPass()";
}

//===----------------------------------------------------------------------===//
// Xla Gpu <-> Cuda Graphs integration.
//===----------------------------------------------------------------------===//

def OutlineCudaGraphsPass :
    Pass<"xla-gpu-outline-cuda-graphs", "mlir::ModuleOp"> {
  let summary = "Outline sequences of Xla Gpu operations into CUDA Graphs";

  let description = [{
    Converts sequences of supported Xla Gpu operations to Cuda Graph capture
    functions, and replaces the original sequences with calls to the Xla Cuda
    Graph runtime API.

    Example:

    ```mlir
    gpu.launch_func @compute::foo args(%arg0: memref<?xf32>)
    gpu.launch_func @compute::bar args(%arg1: memref<?xf32>)
    ```

    becomes:

    ```mlir
    // Export cuda graph capture function to Xla runtime.
    rt.export @capture ordinal 1
    func.func @capture(@arg0: memref<?xf32>, %arg1: memref<?xf32>) {
      ... capture a graph corresponding to a sequence of `gpu.launch_func` ops
    }

    // Replace a sequence of graph launch operations with a call to runtime API.
    call @xla.gpu.cuda.graph.launch(%arg0: memref<?xf32>,
                                     %arg1: memref<?xf32>)
      attributes { capture = @capture }
    ```
  }];

  let constructor = "createOutlineCudaGraphsPass()";

  let options = [
    Option<"min_graph_size_", "min_graph_size", "int64_t", /*default=*/"2",
           "The minimum size of the outlined CUDA graph function.">,
  ];
}

//===----------------------------------------------------------------------===//
// Add concurrent regions to CUDA graph capture functions.
//===----------------------------------------------------------------------===//

def AddConcurrentRegionsPass:
    Pass<"xla-gpu-add-concurrent-regions", "mlir::func::FuncOp"> {
  let summary = "Identify and mark concurrent regions in CUDA graph capture "
                "functions";

  let description = [{
    Add concurent region markers to indicate a region of operations that can be
    executed concurrently.

    Example:

    ```mlir
    func.func @capture.cuda.graph() {
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func

      // Everything here can run concurrently
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      // Back to sequential execution

      call @xla.gpu.launch.func
      func.return
    }
    ```

    becomes:

    ```mlir
    func.func @capture.cuda.graph() {
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func

      call @xla.gpu.concurrent_region.begin()
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      call @xla.gpu.launch.func
      call @xla.gpu.concurrent_region.end()

      call @xla.gpu.launch.func
      func.return
    }
    ```

  }];

  let constructor = "createAddConcurrentRegionsPass()";
}

//===----------------------------------------------------------------------===//
// Stream assignment.
//===----------------------------------------------------------------------===//

def StreamAssignmentPass:
    Pass<"xla-gpu-stream-assignment", "mlir::func::FuncOp"> {
  let summary = "Identify and mark concurrent regions in CUDA graph capture "
                "functions";

  let description = [{
    Assign a stream to each kernel launch in the capture function. Streams are
    assigned to exploit parallelism, so that we can build parallel GPU graphs
    duing graph capture.

    Example:

    ```mlir
    func.func @capture.cuda.graph() {
      // func1, func2, func3 can run in parallel
      call @xla.gpu.launch.func1
      call @xla.gpu.launch.func2
      call @xla.gpu.launch.func3

      // Depends on xla.gpu.launc.func1 and xla.gpu.launch.func2 to finish.
      call @xla.gpu.launch.func
      func.return
    }
    ```

    becomes:

    ```mlir
    func.func @capture.cuda.graph() {
      // func1, func2, func3 can run in parallel
      call @xla.gpu.launch.func1 {stream = 0 : i64}
      call @xla.gpu.launch.func2 {stream = 1 : i64}
      call @xla.gpu.launch.func3 {stream = 2 : i64}

      // Add explicit synchronization to wait for stream 1 to finish executing
      // func2. 
      xla.stream.await {from = 0, to = 1}
      call @xla.gpu.launch.func {stream = 0: i64}
      func.return
    }
    ```

  }];

  let constructor = "createStreamAssignmentPass()";
}

#endif  // XLA_GPU_PASSES
