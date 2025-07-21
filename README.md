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

### Running Tests

```bash
docker-compose run --rm test
```

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
