# che-android-studio — Eclipse Che + KasmVNC + Android Studio / ASfP dev
# environment. Thin wrapper over podman/docker for the container builds.

IMAGE_PREFIX       ?= ghcr.io/kirkbrauer/che-android-studio
VERSION            ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
TLS_VERIFY         ?= true
# podman by default (the `push` target uses podman's --tls-verify flag). `docker`
# works for the build targets; for `make push` with docker, drop --tls-verify.
CONTAINER_TOOL     ?= podman

# Android API levels baked into the SDK image (space-separated). Override e.g.
#   make sdk-image ANDROID_API_LEVELS="33 34 35 36" ANDROID_BUILD_TOOLS="34.0.0 36.0.0"
ANDROID_API_LEVELS ?= 34 36
ANDROID_BUILD_TOOLS ?= 34.0.0 36.0.0

# Five images across the split (build order matters: SDK first, then the dev
# images that FROM it, then the injectors).
SDK_IMAGE          ?= sdk
ASFP_DEV_IMAGE     ?= asfp-dev
STUDIO_DEV_IMAGE   ?= studio-dev
ASFP_ED_IMAGE      ?= asfp-editor
STUDIO_ED_IMAGE    ?= studio-editor

.PHONY: help
help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: register-editors
register-editors: ## Register the Che editor definitions (auto-detects namespace).
	./hack/register-editors.sh

# Build helper: $(1)=image name, $(2)=Containerfile, $(3)=extra build args.
define build_image
	$(CONTAINER_TOOL) build $(3) \
		-t $(IMAGE_PREFIX)/$(1):$(VERSION) \
		-t $(IMAGE_PREFIX)/$(1):latest \
		-f $(2) container/
endef

.PHONY: sdk-image
sdk-image: ## Build the standalone SDK image (configurable API levels).
	$(call build_image,$(SDK_IMAGE),container/sdk/Containerfile,\
		--build-arg ANDROID_API_LEVELS="$(ANDROID_API_LEVELS)" \
		--build-arg ANDROID_BUILD_TOOLS="$(ANDROID_BUILD_TOOLS)")

.PHONY: dev-images
dev-images: ## Build both dev images (require the sdk image present).
	$(call build_image,$(ASFP_DEV_IMAGE),container/dev/asfp/Containerfile,--build-arg IMAGE_PREFIX=$(IMAGE_PREFIX))
	$(call build_image,$(STUDIO_DEV_IMAGE),container/dev/studio/Containerfile,--build-arg IMAGE_PREFIX=$(IMAGE_PREFIX))

.PHONY: editor-images
editor-images: ## Build both IDE injector images.
	$(call build_image,$(ASFP_ED_IMAGE),container/editor/Containerfile,--build-arg IDE_FLAVOR=asfp)
	$(call build_image,$(STUDIO_ED_IMAGE),container/editor/Containerfile,--build-arg IDE_FLAVOR=studio)

.PHONY: images
images: sdk-image dev-images editor-images ## Build all five images (in order).

.PHONY: push
push: ## Push all five images (:VERSION + :latest).
	@for img in $(SDK_IMAGE) $(ASFP_DEV_IMAGE) $(STUDIO_DEV_IMAGE) $(ASFP_ED_IMAGE) $(STUDIO_ED_IMAGE); do \
		$(CONTAINER_TOOL) push --tls-verify=$(TLS_VERIFY) $(IMAGE_PREFIX)/$$img:$(VERSION); \
		$(CONTAINER_TOOL) push --tls-verify=$(TLS_VERIFY) $(IMAGE_PREFIX)/$$img:latest; \
	done
