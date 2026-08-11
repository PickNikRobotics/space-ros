# syntax=docker/dockerfile:1
# Copyright 2021 Open Source Robotics Foundation, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
# This is a multi-stage Dockerfile. Two variants are produced from it,
# selected with `--build-arg IMAGE_VARIANT`:
#
#   * main (default) - a bare-bones installation of the Space ROS packages.
#   * dev            - the full Space ROS workspace plus dev tooling, the test
#                      linters, and IKOS for static analysis.
#
# Build the final image with `--target image`; the test stage and the
# repos-generation helper are exposed as their own targets (see the Makefile).
###############################################################################

# Global build arguments. Re-declare (without a default) inside any stage that
# needs them.
# hadolint ignore=DL3064
ARG USERNAME="spaceros-user"
# Selects build and runtime behaviour: "main" or "dev".
ARG IMAGE_VARIANT="main"

###############################################################################
### PreInstallation Stage
# Sets up the base image with the dependencies required by the later stages.
###############################################################################
FROM ubuntu:noble AS pre-installation
# hadolint ignore=DL3064
ARG USERNAME

# Use bash with pipefail so a failing command in any RUN pipe fails the build
# (DL4006). Inherited by every stage built FROM this one.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO="jazzy"
ENV HOME="/home/${USERNAME}"
ENV SPACEROS_DIR="/opt/ros/spaceros"
# Fixed product path. The export stages (export-repos, export-build-test) copy
# from this absolute location, so it is intentionally not an overridable arg.
ENV WORKSPACE_DIR="/spaceros_ws"
RUN mkdir -p ${WORKSPACE_DIR}
WORKDIR ${WORKSPACE_DIR}

# Set the locale. ubuntu:noble ships /etc/dpkg/dpkg.cfg.d/excludes, which drops
# man pages and .mo translations as packages unpack, so no further locale or
# documentation pruning (localepurge and friends) buys anything on top.
RUN apt-get update && apt-get install --no-install-recommends -y locales \
    && rm -rf /var/lib/apt/lists/*
RUN locale-gen en_US en_US.UTF-8
RUN update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8

# The following commands are based on the source install for ROS 2 Rolling Ridley.
# See: https://docs.ros.org/en/ros2_documentation/rolling/Installation/Ubuntu-Development-Setup.html
# The main variation is getting Space ROS sources instead of the Rolling sources.

# Add the ROS 2 apt repository
RUN apt-get update && apt-get install --no-install-recommends -y \
      curl \
      gnupg \
      lsb-release \
      python3-pip \
      python3-setuptools \
      software-properties-common \
    && rm -rf /var/lib/apt/lists/*
RUN add-apt-repository universe
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
# Register the ROS 2 apt source. Downstream stages run their own `apt-get update`
# before installing, so no index is primed (and left dangling) here.
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

###############################################################################
### PreInstallation Build Stage
# The toolchain needed to compile from source. Every build-time stage derives
# from here; prepare-image stays on pre-installation, so none of it reaches the
# main image.
###############################################################################
FROM pre-installation AS pre-installation-build
RUN apt-get update && apt-get install --no-install-recommends -y \
      bison \
      build-essential \
      cmake \
      git \
      wget \
    && rm -rf /var/lib/apt/lists/*

###############################################################################
### Setup Stage
# Sets up the ROS 2 workspace repos manifest (output.repos).
###############################################################################
FROM pre-installation-build AS setup
# Install required software development tools and ROS tools
RUN apt-get update && apt-get install --no-install-recommends -y \
      python3-rosinstall-generator \
    && rm -rf /var/lib/apt/lists/*

COPY scripts ./
COPY excluded-pkgs.txt spaceros-pkgs.txt spaceros.repos ./

# This is a fresh image, so we do not need to exclude installed packages.
ENV AMENT_PREFIX_PATH=${SPACEROS_DIR}
RUN sh generate-repos.sh \
               --outfile ros2.repos \
               --packages spaceros-pkgs.txt \
               --excluded-packages excluded-pkgs.txt \
               --rosdistro "${ROS_DISTRO}"
RUN python3 merge-repos.py ros2.repos spaceros.repos -o output.repos

###############################################################################
### Export Repos Stage
# Exports the generated repos manifest to the host. Build with
# `--target export-repos --output type=local,dest=.` to write ./ros2.repos.
###############################################################################
FROM scratch AS export-repos
COPY --from=setup /spaceros_ws/output.repos /ros2.repos

###############################################################################
### IKOS Installation
# Builds IKOS and its dependencies from source for use as a static analysis
# tool in the dev image. See: https://github.com/space-ros/docker/issues/99
###############################################################################
FROM pre-installation-build AS ikos-install

RUN apt-get update && apt-get install --no-install-recommends --yes \
    gcc \
    g++ \
    cmake \
    libgmp-dev \
    libboost-dev \
    libboost-filesystem-dev \
    libboost-thread-dev \
    libboost-test-dev \
    libsqlite3-dev \
    libtbb-dev \
    libz-dev \
    libedit-dev \
    python3 \
    python3-pip \
    python3-venv \
    llvm-14 \
    llvm-14-dev \
    llvm-14-tools \
    clang-14 \
    ros-dev-tools \
    && rm -rf /var/lib/apt/lists/*

RUN git clone -b v3.5 --depth 1 https://github.com/NASA-SW-VnV/ikos.git
WORKDIR ${WORKSPACE_DIR}/ikos/build
RUN cmake \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_STANDARD_REQUIRED=ON \
    -DCMAKE_INSTALL_PREFIX="/opt/ikos" \
    -DCMAKE_BUILD_TYPE="Release" \
    -DLLVM_CONFIG_EXECUTABLE="/usr/lib/llvm-14/bin/llvm-config" \
    .. \
    && make -j"$(nproc)" \
    && make install
WORKDIR ${WORKSPACE_DIR}
RUN rm -rf ikos

###############################################################################
### IKOS source stages
# `image` copies IKOS from `ikos-${IMAGE_VARIANT}`. For dev this is the
# populated install; for main it is an empty directory so the COPY is a no-op
# the main image discards.
###############################################################################
FROM ikos-install AS ikos-dev

FROM pre-installation AS ikos-main
RUN mkdir -p /opt/ikos

# Resolve the variant-specific IKOS source. `--from` does not expand build
# args, but `FROM` does (from a global-scope ARG), so select the stage here.
FROM ikos-${IMAGE_VARIANT} AS ikos-selected

###############################################################################
### Sources Stage
# Fetches the ROS 2 workspace sources.
###############################################################################
FROM setup AS sources

RUN apt-get update && apt-get install --no-install-recommends -y \
      python3-vcstool \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir src -p \
    && vcs import --retry 3 src < output.repos \
    && vcs export --exact src > exact.repos

###############################################################################
### Rosdep Stage
# Resolves the system dependencies of the workspace into two scripts:
# rosdeps.sh (everything, for building) and rosdeps-exec.sh (what the workspace
# needs to run, for the main image).
###############################################################################
FROM pre-installation-build AS rosdep
# Re-declare so the pipe in the rosdeps.sh generation step fails on error
# (hadolint does not track SHELL inheritance across FROM).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Rosdep updates
RUN apt-get update && apt-get install --no-install-recommends -y python3-rosdep \
    && rosdep init \
    && rosdep update \
    && rm -rf /var/lib/apt/lists/*

# Copy sources and exclusion lists
COPY --from=sources /spaceros_ws/src ./src
COPY excluded-pkgs.txt excluded-deps.txt ./

# Resolve system package dependencies using rosdep
# urdfdom_headers is cloned from source, however rosdep can't find it.
# It is because package.xml manifest is missing. See: https://github.com/ros/urdfdom_headers
# Additionally, IKOS must be excluded as per: https://github.com/space-ros/docker/issues/99
RUN rosdep install -y \
      --from-paths src --ignore-src \
      --simulate \
      --rosdistro "${ROS_DISTRO}" \
      --skip-keys "$(tr '\n' ' ' < 'excluded-pkgs.txt') urdfdom_headers ikos" > rosdeps.txt

# The same resolution restricted to exec dependencies: what the workspace needs
# to run rather than to compile. The main image installs only these.
RUN rosdep install -y \
      --from-paths src --ignore-src \
      --simulate \
      --dependency-types exec \
      --rosdistro "${ROS_DISTRO}" \
      --skip-keys "$(tr '\n' ' ' < 'excluded-pkgs.txt') urdfdom_headers ikos" > rosdeps-exec.txt

# Process both dependency sets into shell scripts
RUN for f in rosdeps rosdeps-exec; do \
      { echo "#!/bin/bash"; \
        echo "apt-get update"; \
        echo "apt-get install -y \\"; \
        grep -v -F -f excluded-deps.txt "${f}.txt" | sed 's/^/  /'; \
      } > "${f}.sh" \
      && chmod +x "${f}.sh"; \
    done

###############################################################################
### Build Stage
# Builds the ROS 2 workspace for either the dev or the main image, selected by
# IMAGE_VARIANT.
###############################################################################
FROM rosdep AS build
ARG IMAGE_VARIANT

# Uncrustify Vendor has vcstool as a dependency
RUN apt-get update && apt-get install --no-install-recommends -y \
      python3-vcstool \
      python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*
RUN bash rosdeps.sh
RUN mkdir -p "${SPACEROS_DIR}"

COPY colcon_ws_config colcon_ws_config

# If Dev, we do not use a merge install for the sake of testing and development.
# If Main, compile the release image. Any other variant is a hard error.
RUN if [ "${IMAGE_VARIANT}" = "dev" ]; then \
      python3 colcon_ws_config/prepare_workspace.py && \
      MAKEFLAGS="-j4" colcon build \
        --metas ./spaceros-linters.meta \
        --install-base "${SPACEROS_DIR}" \
        --merge-install \
        --parallel-workers 4 \
        --cmake-args \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCMAKE_CXX_FLAGS="--param ggc-min-expand=20" \
        -DCMAKE_C_FLAGS="--param ggc-min-expand=20" \
        --no-warn-unused-cli; \
    elif [ "${IMAGE_VARIANT}" = "main" ]; then \
      MAKEFLAGS="-j4" colcon build \
        --install-base "${SPACEROS_DIR}" \
        --merge-install \
        --parallel-workers 4 \
        --cmake-args \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCMAKE_CXX_FLAGS="--param ggc-min-expand=20" \
        -DCMAKE_C_FLAGS="--param ggc-min-expand=20" \
        --no-warn-unused-cli; \
    else \
      echo "Unknown IMAGE_VARIANT: '${IMAGE_VARIANT}' (expected 'main' or 'dev')" >&2; exit 1; \
    fi

# Strip what only a build against this install needs. Done here, before the
# image stage COPYs ${SPACEROS_DIR}, so the bytes never enter the final image.
# The dev image keeps them: building against the workspace is its purpose.
RUN if [ "${IMAGE_VARIANT}" != "dev" ]; then \
      rm -rf "${SPACEROS_DIR}/include" \
      && find "${SPACEROS_DIR}/share" -type d -name cmake -prune -exec rm -rf {} + \
      && find "${SPACEROS_DIR}/share" \( -name "*.cmake" -o -name CMakeLists.txt \) -delete \
      && find "${SPACEROS_DIR}" -name "*.pyc" -delete \
      && find "${SPACEROS_DIR}" -type d -name __pycache__ -empty -delete; \
    fi

###############################################################################
### Build Test Stage
# Runs the tests on the (dev) ROS 2 workspace and assembles the build results
# archive. Build with `--build-arg IMAGE_VARIANT=dev`.
###############################################################################
FROM build AS build-test

# Install dependencies for testing
RUN apt-get update && apt-get install --no-install-recommends -y \
      clang-tidy \
      cppcheck \
      google-mock \
      graphviz \
      pydocstyle \
      pyflakes3 \
      python3-argcomplete \
      python3-flake8 \
      python3-matplotlib \
      python3-mypy \
      python3-nose \
      python3-pycodestyle \
      python3-pydocstyle \
      python3-pytest \
      python3-pytest-cov \
      python3-pytest-mock \
      python3-pytest-repeat \
      python3-pytest-rerunfailures \
      python3-pytest-timeout \
      uncrustify \
    && rm -rf /var/lib/apt/lists/*

RUN . "${SPACEROS_DIR}/setup.sh" && \
    colcon test \
      --install-base "${SPACEROS_DIR}" \
      --merge-install \
      --retest-until-pass 2 \
      --packages-skip ament_lint \
      --ctest-args -LE "(ikos|xfail)" \
      --ctest-args "--output-on-failure" \
      --pytest-args -m "not xfail" \
      --pytest-args "--disable-warnings" \
      --event-handlers console_cohesion+

RUN . "${SPACEROS_DIR}/setup.sh" && \
    ros2 run process_sarif make_build_archive

###############################################################################
### Export Build Test Stage
# Exports the build results archive to the host. Build with
# `--target export-build-test --output type=local,dest=log/build_results_archives`.
###############################################################################
FROM scratch AS export-build-test
COPY --from=build-test /spaceros_ws/log/build_results_archives/ /

###############################################################################
### Prepare Image Stage
# Prepares a fresh runtime base with the resolved system dependencies already
# installed, saving build time when assembling the final image.
###############################################################################
FROM pre-installation AS prepare-image

# Add missing runtime dependencies. openssh-client and less serve the git that
# the dev image installs via ros-dev-tools; they would arrive as its Recommends,
# which --no-install-recommends drops.
RUN apt-get update && apt-get install --no-install-recommends -y \
      less \
      libspdlog-dev \
      openssh-client \
      python3-catkin-pkg \
      python3-lark \
      python3-netifaces \
      python3-numpy \
      python3-packaging \
      python3-psutil \
      python3-yaml \
      sudo \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

# Prepare the image
RUN mkdir -p "${SPACEROS_DIR}"
COPY --from=rosdep /spaceros_ws/rosdeps.sh ${SPACEROS_DIR}/rosdeps.sh
COPY --from=rosdep /spaceros_ws/rosdeps-exec.sh ${SPACEROS_DIR}/rosdeps-exec.sh
# These are rosdep's own `apt-get install -y <pkg>` output, so the flag has no
# command line to go on; what Recommends drag in here is manpages-dev, fonts and
# X libs. The config stays for the image stage and is dropped by its cleanup.
# Apt lists are cleaned in this layer, not in the one above it.
RUN printf 'APT::Install-Recommends "false";\n' > /etc/apt/apt.conf.d/99no-recommends \
    && bash "${SPACEROS_DIR}/rosdeps-exec.sh" \
    && rm -rf /var/lib/apt/lists/*

###############################################################################
### Image Stage
# Assembles the final image with the built ROS 2 workspace. Variant-specific
# behaviour (IKOS + dev tooling vs. a cleaned bare-bones install) is selected
# by IMAGE_VARIANT.
###############################################################################
FROM prepare-image AS image
ARG IMAGE_VARIANT
# hadolint ignore=DL3064
ARG USERNAME
# Re-declare so the excluded-deps pipe in the dev branch fails on error
# (hadolint does not track SHELL inheritance across FROM).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=build /opt/ros/spaceros ${SPACEROS_DIR}
COPY --from=sources /spaceros_ws/exact.repos ${SPACEROS_DIR}/scripts/spaceros.repos
COPY scripts/generate-repos.sh scripts/merge-repos.py ${SPACEROS_DIR}/scripts/
RUN chmod +x "${SPACEROS_DIR}/scripts/generate-repos.sh" "${SPACEROS_DIR}/scripts/merge-repos.py" \
    && mv "${SPACEROS_DIR}/rosdeps.sh" "${SPACEROS_DIR}/scripts/rosdeps.sh" \
    && rm -f "${SPACEROS_DIR}/rosdeps-exec.sh"

# Post installation: IKOS source is selected by variant (empty for main).
COPY --from=ikos-selected /opt/ikos /opt/ikos
COPY excluded-deps.txt /tmp/excluded-deps.txt

# If Dev, restore the build dependencies prepare-image left out, then install
# IKOS dependencies and the excluded (test) dependencies.
# If Core, we only care about the install, so then clear the workspace.
#
# Move off ${WORKSPACE_DIR} first: the main branch deletes it, and the shared
# cleanup chain below (pip cache purge) fails if it runs from a deleted CWD.
WORKDIR /
RUN if [ "${IMAGE_VARIANT}" = "dev" ]; then \
      apt-get update && apt-get install --no-install-recommends -y \
        gcc \
        g++ \
        cmake \
        file \
        libgmp-dev \
        libboost-dev \
        libboost-filesystem-dev \
        libboost-thread-dev \
        libboost-test-dev \
        libsqlite3-dev \
        libtbb-dev \
        libz-dev \
        libedit-dev \
        python3 \
        python3-pip \
        python3-venv \
        llvm-14 \
        llvm-14-dev \
        llvm-14-tools \
        clang-14 \
        ros-dev-tools && \
      bash "${SPACEROS_DIR}/scripts/rosdeps.sh" && \
      grep -v '^#' /tmp/excluded-deps.txt | xargs apt-get install --no-install-recommends -y; \
    elif [ "${IMAGE_VARIANT}" = "main" ]; then \
      rm -rf "${WORKSPACE_DIR}" /opt/ikos; \
    else \
      echo "Unknown IMAGE_VARIANT: '${IMAGE_VARIANT}' (expected 'main' or 'dev')" >&2; exit 1; \
    fi \
    && rm -f /tmp/excluded-deps.txt /etc/apt/apt.conf.d/99no-recommends \
    && rm -rf /var/lib/apt/lists/* /tmp/pip-reqs /var/cache/apt/archives \
    && apt-get clean \
    && pip cache purge

# IKOS lives at /opt/ikos only in the dev image. It is added to PATH at runtime
# by the entrypoint (gated on /opt/ikos/bin existing) so the bare-bones main
# image keeps a clean environment.

# fix ubuntu24 issue.
# some base ubuntu24 docker images have uid 1000 for 'ubuntu' user (ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash).
# this is a change in behaviour from ubuntu22 base images where there was no uid 1000.
# this clashes with default host uid of 1000 later when tryin to mount external volumes from host.
# https://askubuntu.com/questions/1513927/ubuntu-24-04-docker-images-now-includes-user-ubuntu-with-uid-gid-1000
RUN userdel -r ubuntu

# Add user and group
RUN useradd --create-home -m -s /bin/bash "${USERNAME}" && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" && \
    cp -r /etc/skel/. "${HOME}"

# Ensure the user has access to the home and install directories
RUN chown -R "${USERNAME}:${USERNAME}" "${HOME}"

USER ${USERNAME}
WORKDIR ${HOME}

# Add the entrypoint
COPY ./docker/entrypoint.sh /entrypoint.sh
RUN echo "source /entrypoint.sh" >> "${HOME}/.bashrc"
ENTRYPOINT ["/entrypoint.sh"]
