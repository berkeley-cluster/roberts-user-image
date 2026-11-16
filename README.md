# roberts-user-image

The default environment for UC Berkeley Roberts Cluster users.

- **Base:** Jupyter Docker Stacks' CUDA PyTorch image
  (`quay.io/jupyter/pytorch-notebook:cuda12-<date>`): Ubuntu, conda,
  Python, JupyterLab, PyTorch with CUDA. Runs as `jovyan` (uid 1000),
  without root.
- **R** from CRAN's Ubuntu repository, with packages from Posit Package
  Manager, pinned to one dated snapshot.
- **RStudio Server,** opened from JupyterLab through
  jupyter-rsession-proxy.
- **code-server** (VS Code in the browser), also through JupyterLab.
- **Tools:** `kubectl` with kubelogin (`kubectl oidc-login`, for
  logging in through authentik) and Kueue's plugin (`kubectl kueue`);
  `cluster-queue`, also `kubectl cluster-queue` (the cluster's queues
  at a glance, like `squeue`; in this repo); Claude Code, git, ssh
  client, tmux, editors.

## Image

Each build is tagged with its date (`YYYY-MM-DD`) and short commit hash;
builds from `main` are also tagged `latest`. Pin a date or hash in
templates rather than `latest`. The cluster's nodes pull them through
the registry's `ghcr` proxy cache.

## Files

| File | Contents |
|---|---|
| `Dockerfile` | the build, in stages; versions are `ARG`s at the top |
| `apt.txt` | Ubuntu packages: system libraries R packages need, and tools |
| `install-r-packages.R` | the R packages, pinned (`package@version`), and their installation into `/srv/r` |
| `Rprofile.site` | R's repositories: the Package Manager snapshot |
| `environment.yml` | additions to the conda environment |
| `.github/workflows/build.yaml` | builds and pushes the image |

## R packages

The package lists come from historical R package usage log: packages loaded by
at least two people between 2024-11-15 and 2026-11-14 (211 of the 1,041 in the
HPC site library), plus editor tooling, and a few widely used packages people
installed themselves.

Packages are pinned in `install-r-packages.R`: CRAN packages as
`package@version`, Bioconductor packages as `bioc::package@version`. One
`renv::install()` call installs both; renv finds Bioconductor's
repositories through BiocManager, which uses the Package Manager mirror
and `BIOC_VERSION` from `Rprofile.site`. Dependencies come from the same
snapshot, so they're fixed too. The build fails if a package is missing
or not at its pinned version.

Packages are in the site library `/srv/r`, read-only. Packages users
install go to their own library in their home directory, from the same
snapshot, so versions match.

## Updating

Change the `ARG`s at the top of the `Dockerfile` together:

- `BASE_IMAGE`: a newer `cuda12-<date>` tag. If its Ubuntu release
  changed, update `UBUNTU_CODENAME` and `R_VERSION` (the CRAN package
  version names the release, e.g. `2604` for 26.04).
- `R_VERSION`: from
  `https://cloud.r-project.org/bin/linux/ubuntu/<codename>-cran40/`.
- `RSTUDIO_VERSION`: Posit's current RStudio Server release.
- `CODE_SERVER_VERSION` and `CODE_SERVER_SHA256`: code-server's
  current release, installed from GitHub rather than conda-forge, whose
  package constrains Node.js. The checksum is the release asset's
  digest:

  ```sh
  gh api repos/coder/code-server/releases/latest --jq \
    '.tag_name, (.assets[] | select(.name | test("linux-amd64.tar.gz$"))
    | .digest)'
  ```
- `KUBECTL_VERSION`: the cluster's Kubernetes version.
- `KUEUE_VERSION` and `KUEUECTL_SHA256`: the cluster's Kueue version,
  and the digest of its `kubectl-kueue-linux-amd64` release asset:

  ```sh
  gh release view "$KUEUE_VERSION" -R kubernetes-sigs/kueue \
    --json assets --jq '.assets[]
    | select(.name == "kubectl-kueue-linux-amd64") | .digest'
  ```
- `KUBELOGIN_VERSION` and `KUBELOGIN_SHA256`: kubelogin's current
  release, and the checksum from its `.sha256` file:

  ```sh
  v=$(gh release view -R int128/kubelogin \
    --json tagName -q .tagName)
  gh release download "$v" -R int128/kubelogin \
    -p kubelogin_linux_amd64.zip.sha256 -O -
  ```
- `environment.yml`: the pinned conda packages.
- `PPM_SNAPSHOT`: a recent date, and `BIOC_VERSION` to match the R
  version. Then update the pins to the new snapshot's versions; pins
  older than the snapshot are compiled from source.

Push to a branch and open a pull request. The workflow builds the
image without pushing. Merge to push it.
