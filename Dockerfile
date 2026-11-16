# syntax=docker/dockerfile:1
#
# Roberts Cluster user image: Jupyter Docker Stacks' CUDA PyTorch image,
# plus R and RStudio Server, code-server, and command-line tools.
#
# Stages (BuildKit builds srv-r and final's conda step in parallel):
#   base     the Jupyter image, plus system R, RStudio Server, and the
#            system libraries R packages need
#   srv-r    R packages, into /srv/r
#   final    conda additions, /srv/r, code-server, tools  (the user image)
#
# A desktop variant is a separate, downstream image, built FROM this one.

ARG BASE_IMAGE=quay.io/jupyter/pytorch-notebook:cuda12-2026-11-15

FROM ${BASE_IMAGE} AS base

# Ubuntu release of the base image, for R's apt repository and Posit
# Package Manager's binaries
ARG UBUNTU_CODENAME=resolute
ARG R_VERSION=4.6.2-2.2604.0
ARG RSTUDIO_VERSION=2026.11.0-203
# Posit Package Manager snapshot for CRAN and Bioconductor
ARG PPM_SNAPSHOT=2026-11-13
ARG BIOC_VERSION=3.23

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# R from CRAN's Ubuntu repository, and system libraries for R packages
COPY apt.txt /tmp/apt.txt
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends gnupg && \
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      | gpg --dearmor -o /usr/share/keyrings/cran.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cran.gpg]" \
      "https://cloud.r-project.org/bin/linux/ubuntu" \
      "${UBUNTU_CODENAME}-cran40/" > /etc/apt/sources.list.d/cran.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      r-base-core="${R_VERSION}" r-base-dev="${R_VERSION}" \
      r-recommended="${R_VERSION}" \
      $(sed 's/#.*//' /tmp/apt.txt) && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/apt.txt

# RStudio Server. Posit's build for Ubuntu 22.04 is the one it serves for
# newer releases too.
RUN curl -fsSL -o /tmp/rstudio.deb \
      "https://download2.rstudio.org/server/jammy/amd64/rstudio-server-${RSTUDIO_VERSION}-amd64.deb" && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends /tmp/rstudio.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/rstudio.deb && \
    ln -s /usr/lib/rstudio-server/bin/quarto/bin/quarto /usr/local/bin/quarto

# R configuration: Package Manager snapshot, and /srv/r as the first
# site library. Users' own packages go to R_LIBS_USER in their home.
COPY Rprofile.site /etc/R/Rprofile.site
RUN sed -i -e "s/@PPM_SNAPSHOT@/${PPM_SNAPSHOT}/g" \
      -e "s/@UBUNTU_CODENAME@/${UBUNTU_CODENAME}/g" \
      -e "s/@BIOC_VERSION@/${BIOC_VERSION}/g" /etc/R/Rprofile.site && \
    echo 'R_LIBS_SITE="/srv/r:/usr/local/lib/R/site-library:/usr/lib/R/site-library:/usr/lib/R/library"' \
      >> /etc/R/Renviron.site

# =========================================================================
FROM base AS srv-r

COPY install-r-packages.R /tmp/
# renv's cache and downloads stay in this stage; only /srv/r is copied
RUN Rscript /tmp/install-r-packages.R && \
    rm -rf /tmp/install-r-packages.R /srv/r/.renv

# =========================================================================
FROM base AS final

ARG KUBECTL_VERSION=v1.37.1
# kubelogin (kubectl oidc-login), for logging in to the cluster through
# authentik; the checksum is the release's .sha256 file
ARG KUBELOGIN_VERSION=v1.36.4
ARG KUBELOGIN_SHA256=9e8baeb4905d35a301304af2548324997add512fe94ab20e65993d167212bf85
# code-server's own release, which bundles its Node.js; conda-forge's
# package would constrain the conda environment's Node.js. The checksum
# is the release asset's digest on GitHub.
ARG CODE_SERVER_VERSION=4.145.2
ARG CODE_SERVER_SHA256=2f6db6c3e8b733dd6b3aeee83532e148b2bae2e392353ba85452d03572348962

# conda additions, as the notebook user like the base image does
COPY --chown=${NB_UID}:${NB_GID} environment.yml /tmp/environment.yml
USER ${NB_UID}
RUN mamba env update -n base -f /tmp/environment.yml && \
    mamba clean -afy && rm /tmp/environment.yml
USER root

COPY --from=srv-r /srv/r /srv/r

# Steps run as root use a throwaway HOME: the base image sets HOME to the
# notebook user's home, which root-owned files would make unwritable.

# R kernel for Jupyter, installed into the conda environment's Jupyter
RUN HOME=/tmp/root-home R --quiet -e \
      "IRkernel::installspec(user = FALSE, prefix = '${CONDA_DIR}')" && \
    rm -rf /tmp/root-home && fix-permissions "${CONDA_DIR}"

# code-server (VS Code in the browser)
RUN curl -fsSL -o /tmp/code-server.tar.gz \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-amd64.tar.gz" && \
    echo "${CODE_SERVER_SHA256}  /tmp/code-server.tar.gz" | sha256sum -c - && \
    mkdir /opt/code-server && \
    tar -xzf /tmp/code-server.tar.gz -C /opt/code-server --strip-components=1 && \
    ln -s /opt/code-server/bin/code-server /usr/local/bin/code-server && \
    rm /tmp/code-server.tar.gz

# kubectl, to run jobs in the user's namespace
RUN curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  /usr/local/bin/kubectl" \
      | sha256sum -c - && \
    chmod 755 /usr/local/bin/kubectl

# kubelogin, installed as the kubectl plugin "oidc-login"
RUN curl -fsSL -o /tmp/kubelogin.zip \
      "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_amd64.zip" && \
    echo "${KUBELOGIN_SHA256}  /tmp/kubelogin.zip" | sha256sum -c - && \
    unzip -p /tmp/kubelogin.zip kubelogin > /usr/local/bin/kubectl-oidc_login && \
    chmod 755 /usr/local/bin/kubectl-oidc_login && \
    rm /tmp/kubelogin.zip

# Claude Code, installed system-wide: the home directory is a volume
RUN HOME=/tmp/root-home npm install -g --prefix "${CONDA_DIR}" \
      @anthropic-ai/claude-code && \
    rm -rf /tmp/root-home && fix-permissions "${CONDA_DIR}"

RUN rm -rf /tmp/*

USER ${NB_UID}
WORKDIR /home/${NB_USER}
