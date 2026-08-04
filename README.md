<img src="./logos/spaceros_white_on_blue.png" alt="Space ROS Logo - White on Blue" width="700"/>

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)

Documentation is at https://space.ros.org

For information on compiling the Space ROS docker image for different purposes, see the [usage instructions](./docs/USAGE.md).

For information on the release process refere to the [release docs](./docs/RELEASE.md).


## Building the Space ROS image

The images are built with `docker buildx`. A `Makefile` wraps the common
commands:

```bash
# To build the base Space ROS image (tagged osrf/space-ros:latest)
make main-image

# To build the dev Space ROS image (tagged osrf/space-ros:dev)
make dev-image
```

See the [usage instructions](./docs/USAGE.md) for the underlying
`docker buildx` invocations and the other build targets.

## Contribution rules

See the [contributing guide](https://github.com/space-ros/.github/blob/master/CONTRIBUTING.md) for details on how to contribute to the Space ROS project.
