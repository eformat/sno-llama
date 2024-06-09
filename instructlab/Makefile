# Image URL to use all building/pushing image targets
REGISTRY ?= quay.io
REPOSITORY ?= $(REGISTRY)/eformat/sno-llama-ilab
ILAB_VERSION ?= 0.14.1

IMG := $(REPOSITORY):${ILAB_VERSION}

# Podman Login
podman-login:
	@podman login -u $(DOCKER_USER) -p $(DOCKER_PASSWORD) $(REGISTRY)

# Build the oci image
podman-build:
	podman build . -t ${IMG} --build-arg ILAB_VERSION=${ILAB_VERSION} -f Dockerfile

# Push the oci image
podman-push: podman-build
	podman push ${IMG}
