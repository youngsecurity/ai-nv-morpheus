<!--
 SPDX-FileCopyrightText: Copyright (c) 2021-2024, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 SPDX-License-Identifier: Apache-2.0

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
-->

# Building Documentation

Additional packages required for building the documentation are defined in `./conda_docs.yml`.

## Install Additional Dependencies
From the root of the Morpheus repo:
```bash
conda env update --solver=libmamba -n morpheus --file conda/environments/dev_cuda-121_arch-x86_64.yaml --prune
```

## Build Morpheus and Documentation
```
CMAKE_CONFIGURE_EXTRA_ARGS="-DMORPHEUS_BUILD_DOCS=ON" ./scripts/compile.sh --target morpheus_docs
```
Outputs to `build/docs/html`
