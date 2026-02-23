# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

# Try installing swig for lldb through choco just to see what happens.
choco install swig

# Install pyyaml
pip install pyyaml

# Install meson. eld support was added in v1.9.0, so we need at least that.
pip install meson==1.10.0
