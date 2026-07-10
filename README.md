# MicroNet

**A web application for modeling and analyzing microbial population growth data.**

MicroNet is a web-based tool that models microbial population dynamics using Gaussian Processes regression. It helps researchers analyze how microbes adapt to various environmental stressors, providing insights into microbial resilience.
The platform is a user-friendly implementation of the AMiGA Python package developed by Firas: https://firasmidani.github.io/amiga/.

---


## 🛠️ Quick Start

#### `For Windows, change the bin/rails setting from CRLF into LF`
#### `For macOS, some modifications to the Dockerfile may be needed`

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

`docker-compose up` starts three services: the Rails **web** server, the **db** (PostgreSQL), and a **delayed_job** worker (`rake jobs:work`) that runs analyses in the background. The worker is what executes the AMiGA commands, so it must be running for submitted jobs to process.

### Running Tests

```bash
docker-compose run --rm test
```

---

## 🔄 How It Works

MicroNet guides the user through four steps, then processes the submitted job in the background and emails the results. The user never has to touch the command line.

### Step 1 — Enter Email
The user enters the email address their results will be sent to. The address must be well-formed or the app blocks progress with an error.

- **Resume a draft:** if the user has an unfinished ("draft") job, MicroNet offers to resume it. Choosing **Yes** returns them to Upload with their previous files intact; **No** discards the old draft and starts fresh.
- **One draft per user:** only the most recent draft is kept — enforced both in the app and by a database constraint — so duplicate drafts (e.g. from two browser tabs) can't pile up.
- **Active-job cap:** each user may have at most **3** concurrently active jobs (queued or running). A fourth submission is blocked with a message to wait for one to finish.

### Step 2 — Upload Files
Users upload a plate-reader **data file** and its matching **mapping file**.

- **Formats:** `.asc`, `.tsv`, `.txt`, `.csv`.
- **Data file:** first column is well positions (e.g. `A1`–`H12`); header row is the measurement time points.
- **Mapping file:** tab-delimited `.txt`; same wells, in the same order, as the data file. MicroNet rejects the upload if wells or delimiters don't match.
- **Multiple plates:** multiple data/mapping pairs can be uploaded together, aligned in matching order.
- **Optional files:** a **metafile** (labels whole plates via a `Plate_ID` field) and an **interval file** (custom measurement intervals; defaults to 600 seconds if omitted).
- **Data file only:** users may upload data file(s) with no mapping file. In that case only Raw Data Plot and an unpooled Gaussian Process Plot are available — the mapping-dependent analyses are disabled until a mapping file is provided.

### Step 3 — Select Analyses
Users pick one or more of the six analyses (see [Features](#-features) below). A few guardrails apply here:

- Heatmap Plot, Test Hypothesis, and Compare Parameters require a mapping file and are disabled without one.
- Heatmap Plot requires a value plus both axis variables before the user can proceed.
- Raw Data Plot requires each data file to contain exactly 96 wells; this is checked at the Review step and bounces the user back with an explanation if not met.
- **Time step size (optional):** for the four Gaussian-Process-based analyses (GP Plot, Fit Statistics, Test Hypothesis, Compare Parameters), users may set a time step size from 1 (default, full resolution) up to 15. Larger values fit the model on fewer time points, lowering memory use on large datasets at some cost to resolution. MicroNet caps the value so at least 8 time points always remain.

### Step 4 — Review & Submit
The user reviews their uploaded files and selected analyses, edits anything via the **Edit** links, and submits. Submission queues the job as a background task and shows a "Submission Successful" page — the user can then navigate away.

### Processing & Results
The delayed_job worker picks the job off the queue and runs the selected analyses by calling AMiGA:

- **Per-analysis isolation:** each analysis runs as an isolated step. If one fails (e.g. a memory limit or bad parameter combination), the others still complete rather than the whole job aborting.
- **Automatic memory retry:** if a GP-based analysis runs out of memory, MicroNet automatically retries it with progressively larger time step sizes before giving up.
- **Outcome:** if at least one analysis produces output, the job is marked **Completed** (or **Completed with warnings** if some failed) and the user is emailed the results plus a note on anything that couldn't finish. If everything fails, the job is marked **Failed** and the user is notified.

---

## 🚀 Features

### 1. Raw Data Plot (Per Well)
Generates a growth curve for each well in the experimental design individually (only works for 96-well plates). When a control column is present in the mapping file, wells with an OD fold-change above 1.5 are highlighted blue and below 0.5 red.

### 2. Gaussian Process Plot
Generates a Gaussian Process plot for a specified experimental property (the pool-by option) with one chosen condition (the subset option), each with a 95% confidence interval.

### 3. Fit Statistics
Summarizes and models growth curves, generating 5 commonly-used metrics as output: AUC (Area Under Curve), Growth Rate, Carrying Capacity, Lag Time, and Doubling Time. Results can optionally be pooled by metadata variables.

### 4. Heatmap Plot
Generates a heatmap of a chosen **Fit Statistics** value across two conditions (the x- and y-axis variables).

### 5. Test Hypothesis
Tests differential growth between two experimental conditions by computing the log Bayes Factor and the functional difference in OD, with a plot of the observed and predicted curves.

### 6. Compare Parameters
Compares individual growth parameters between two conditions of a variable, reporting the mean and 95% confidence interval for each and whether the difference is significant.

---

## 🔐 Admin

The password-protected Admin section provides a dashboard of all submitted jobs, organized into **Draft, Queued, Running, Completed, Failed, and Cancelled** views (with submitting user, timestamps, and queue position). Administrators can cancel a queued or running job — which emails the affected user automatically — and update their own username or password.

---

## ⚙️ System Overview

<p align="center">
  <img src="https://gitlab.oit.duke.edu/schmid-lab/micronet-app/-/raw/final_cleanup/manuscript/workflow.png" alt="Workflow Diagram" width="600"/>
</p>

MicroNet is a Ruby on Rails app following the model-view-controller (MVC) pattern:

- **AMiGA commands** are executed in `app/models/job.rb` (background worker).
- **Views** (HTML/ERB) are in `app/views`.
- **Controllers** are in `app/controllers`.
- **Background jobs** run via delayed_job; the worker and web server are separate processes so long analyses don't block the UI.

---


## ⚠️ Notes

### 1. Server Testing.
MicroNet analyses run on the machine hosting the app (the delayed_job worker). Additional system testing is recommended before scaling up deployment.

### 2. Device Memory Requirement.
Certain analyses (such as **Fit Statistics** and **Test Hypothesis**) are memory-intensive. MicroNet mitigates this by auto-retrying with larger time step sizes, but inadequate system memory may still result in computation failures on very large datasets.

---


## 🤝 Acknowledgment

### 🌟This is the final product of Code+ 2026 building upon the work of Data+ 2025🌟

Code+ Team: Katherine Bong, Linda Mazengia, Michelle Lan

Data+ Team: Fan Xu, Ziqi Li, James Peng, Uzoma Uwazurike Jr., Abdulrahman Alalyani.

Special thanks to:
- The Schmid Lab for project guidance and resources.
- The Duke OIT Research Computing team for infrastructure and support.
- All contributors and testers who helped improve the tool.
