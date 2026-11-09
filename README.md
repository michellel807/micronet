# MicroNet

**A web application for modeling and analyzing microbial population growth data.**

MicroNet is a web-based tool that models microbial population dynamics using Gaussian Processes regression. It helps researchers analyze how microbes adapt to various environmental stressors, providing insights into microbial resilience.
The platform is a user-friendly implementation of the AMiGA Python package developed by Firas: https://firasmidani.github.io/amiga/.

---


## 🛠️ Quick Start

#### `For Windows, change the bin/rails setting from CRLF into LF`
#### `For macOS, some modifications to the Dockerfile may be needed`

The container uses Ruby 4.0.9, Rails 8.1.4, and Python 3.12. Browser assets
use Sprockets/import maps; Node, Yarn, and Webpacker are not required.
Dependency compatibility limits, security fixes, and deployment follow-ups are
recorded in [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

### 1. Build the web with docker.

```bash
docker-compose build web
```

### 2. Copy the .env.example into place.

```bash
cp .env.example .env
```

### 3. Create the database.

```bash
docker-compose run --rm web bash -c "bin/rails db:create"
```

### 4. Migrate the database.

```bash
docker-compose run --rm web bash -c "bin/rails db:migrate RAILS_ENV=development"
```

### 5. Access the Application

- **Web App**: http://localhost:3000
- **Email Interface**: http://localhost:9000

---

## 🔧 Development

### Starting Development Server

```bash
# Remove stale server PID if switching branches
rm -f tmp/pids/server.pid

# Start development server
docker-compose up

# End all services
docker-compose down
```

Local development runs at http://localhost:3000. The Nginx HTTPS proxy is
optional and starts only with `docker compose --profile server up`. It requires
the server's `micronet-01.oit.duke.edu` certificates under `/etc/letsencrypt`.

### Running Tests

```bash
docker-compose run --rm test
docker compose run --rm web python -m unittest discover -s test/scripts -p '*_test.py'
docker compose run --rm web bin/security
```

The Python suite includes the RNA-seq DESeq2 tests
(`test/scripts/deseq2_analysis_test.py`), which need the image's R and DESeq2
and are skipped where `Rscript` is unavailable. They compare
`lib/scripts/rnaseq/deseq2_analysis.R` with an independent reference, check
recovery of simulated truth, and check input validation. Regenerate the example
RNA-seq inputs with
`docker compose run --rm web python test/scripts/rnaseq_simulation.py lib/examplefiles/rnaseq`
(add `--time-course` for the time-course example).

RNA-seq jobs run as `RnaSeqAnalyzer` Delayed::Jobs (`app/models/rna_seq/pipeline.rb`):
DESeq2, then plots, then a zip with a README that is emailed to the user.
Three experiment types are supported (`lib/scripts/rnaseq/R/designs.R`):
`two_condition` (Wald test, PCA/MA/volcano plots), and two likelihood ratio
tests with time points as categories: `time_course` (does a gene change over
time, optionally within one condition) and `condition_by_time` (does it change
differently over time between two conditions). Time courses also write
`group_means_vst.tsv`, the mean VST per condition and time point with numeric
times, for trajectory modeling, and plot the top genes over time. On the website, choose "RNA-seq differential expression" on the
home page, then upload a count matrix and sample sheet (`RnaSeqController`,
pages under `/rnaseq`); the example files are linked from the upload page.
To queue the example dataset without the website, run
`docker compose run --rm web bin/rails "rnaseq:submit_example[you@example.com]"`.
The `delayed_job` worker processes jobs and the emails appear at
http://localhost:9000. `RNASEQ_ATTACHMENT_LIMIT_MB` (default 20) sets the
largest zip that is emailed; larger results send only the summary files.

To create the first administrator, set `ADMIN_INITIAL_PASSWORD` to a unique
password of at least 12 characters before running `rails db:seed`.
`ADMIN_INITIAL_USERNAME` defaults to `admin`. Seeding preserves an existing
administrator's password.

Edit `requirements.in`, then refresh the Python lockfile in the container with:

```sh
uv pip compile --python-version 3.12 --python-platform x86_64-manylinux_2_28 \
  --upgrade --generate-hashes requirements.in -o requirements.txt
```

The PostgreSQL service is pinned to the current 16.15 patch release. Major
database upgrades require a separate data migration before changing the image
tag. Pull the updated service images with `docker compose pull`.

Uploads stay in a temporary workspace until the user submits an analysis.
Submission creates the job and moves its inputs to `private/uploads/jobs/<id>`.
Existing submitted jobs retain their previously emailed numbers. New jobs use
their database ID, assigned at submission, without a separate numbering counter.

The Docker worker schedules hourly cleanup of temporary workspaces inactive for
24 hours. When starting workers outside Docker, run
`bundle exec rake uploads:schedule_cleanup jobs:work` to enable the same cleanup.
For a manual cleanup, run `bundle exec rake uploads:cleanup_temporary`.

---

## 🚀 Features

### 1. Raw Data Plot (Per Well)
This analysis generates a growth curve for each well in the experimental design individually
(only works for 96-well plates).

### 2. Gaussian Process Plot
This analysis will generate a Gaussian Process plot for a specified experimental property (the pool by option) with one chosen condition (the subset option).

### 3.Fit Statistics
This analysis summarizes and models growth curves, generating 5 commonly-used metrics as output: AUC (Area Under Curve), Growth Rate, Carrying Capacity, Lag Time, and Doubling Time.

### 4. Heatmap Plot
This analysis will generate a heatmap with values from **Fit Statistics** for the conditions (x and y axis) chosen.

### 5. Test Hypothesis
This analysis tests differential growth between distinct experimental conditions by computing the log Bayes Factor scores and the functional difference in the OD.

### 6. Compare Parameters
This analysis compares parameters between two conditions of a variable.

---

## ⚙️ System Overview

<p align="center">
  <img src="https://gitlab.oit.duke.edu/schmid-lab/micronet-app/-/raw/final_cleanup/manuscript/workflow.png" alt="Workflow Diagram" width="600"/>
</p>

- All the AMiGA commands are executed in app\models\job.rb
- All the HTML files are in app\views
- All the controllers are in app\controllers

---


## ⚠️ Notes

### 1. Server Testing.
All Micronet analyses are currently run on the local version. Additional system testing is required before deploying to the server.

### 2. Device Memory Requirement.
Certain analyses (such as **Fit Statistics** and **Test Hypothesis**) are memory-intensive. Inadequate system memory may result in computation failures.

---


## 🤝 Acknowledgment

### 🌟This is the final product of Data+ 2025🌟

Team members: Fan Xu, Ziqi Li, James Peng, Uzoma Uwazurike Jr., Abdulrahman Alalyani.

Special thanks to:
- The Schmid Lab for project guidance and resources.
- The Duke OIT Research Computing team for infrastructure and support.
- All contributors and testers who helped improve the tool.
