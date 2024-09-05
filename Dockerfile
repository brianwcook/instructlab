FROM nvidia/cuda:12.6.1-devel-ubuntu22.04 AS base
# TODO research: possibly use the smaller cuda image?
#FROM nvidia/cuda:12.2.2-base-ubuntu22.04

# create a user, specific UID/GID is not necessisarily important, but designed to run as any `--user`
RUN set -eux; \
	groupadd -r redhat --gid=999; \
	useradd -r -g redhat --uid=999 --home-dir=/instructlab --shell=/bin/bash redhat; \
	install --verbose --directory --owner redhat --group redhat --mode 1777 /instructlab

ENV IL_VERSION v0.17.1

WORKDIR /instructlab
RUN set -eux; \
	apt-get update; \
	apt-get install -y -V --no-install-recommends \
		automake \
		git \
		python3-dev \
		python3-pip \
	; \
	rm -rf /var/lib/apt/lists/*;

FROM base AS build
# ideally we'd just install instructlab in the "base" and run "ilab config init --model-path..." but our desired instructlab doesn't run without libcuda that is only available at runtime, so we'll install a non-cuda version for "config init" and "model download"
RUN set -eux; \
	pip install --no-cache instructlab==${IL_VERSION};

# setup config for the model we want to embed
RUN set -eux; \
	ilab config init --non-interactive --model-path models/granite-7b-lab-Q4_K_M.gguf

# download the model
RUN set -eux; \
	ilab model download --repository instructlab/granite-7b-lab-GGUF --filename granite-7b-lab-Q4_K_M.gguf; \
# ideally at this point, we would just "COPY --link ... /instructlab/models /instructlab/models" but BuildKit insists on creating the parent directories (perhaps related to https://github.com/opencontainers/image-spec/pull/970), and does so with unreproducible timestamps, so we instead create a whole new "directory tree" that we can "COPY --link" to accomplish what we want
	mkdir /target /target/instructlab/ /target/instructlab/models; \
	mv models/granite-7b-lab-Q4_K_M.gguf /target/instructlab/models/; \
	# TODO also copy the generated config or taxonomy?
	\
# save a timestamp related to the model so it can be used for reproducibility (like creation time, last updated, etc); this will make the `COPY --link` layer more reproducible so that it can be reused/recreated across multiple instructlab or cuda versions and updates
# here is an example "git clone" on the hugginface repo to use the commit timestamp (skip lfs since we used ilab to get the model files)
	git clone -b main https://huggingface.co/instructlab/granite-7b-lab-GGUF; \
	sourceDate="$(git -C granite-7b-lab-GGUF log -1 --format=%cd --date=iso granite-7b-lab-Q4_K_M.gguf)"; \
	savedDate="$(date -d "$sourceDate" '+%Y%m%d%H%M.%S')"; \
	find /target -exec touch -t "$savedDate" '{}' +

FROM base

# install cuda based instructlab
RUN set -eux; \
	export CMAKE_ARGS="-DLLAMA_CUDA=on -DLLAMA_NATIVE=off"; \
	pip install --no-cache instructlab[cuda]==${IL_VERSION}; \
	# really remove pip cache
	rm -rf /root/.cache
	# TODO install and remove packages that are only needed for "pip install" rather than relying on "base" stage (or cuda:*-devel)?

# copy the specially crafted folders with the model as a `--link` layer so that it is a reproducible layer
COPY --from=build --link /target/ /
