"""Negative-binomial RNA-seq counts with known truth, for testing the DESeq2 stage.

Counts follow the model DESeq2 assumes:
    K_ij ~ NB(mean = s_j * q_i * 2^(beta_i * x_j), dispersion = alpha_i)
with per-sample size factors s_j, per-gene base means q_i, a mean-dependent
dispersion trend, and true log2 fold changes beta_i for a known set of genes.

Running this file writes example inputs (add --annotations for a gene
annotation table with known enrichment, for the functional enrichment stage):
    python test/scripts/rnaseq_simulation.py lib/examplefiles/rnaseq --seed 2026 --annotations
    python test/scripts/rnaseq_simulation.py lib/examplefiles/rnaseq --time-course --seed 2026 --annotations
"""
import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


@dataclass
class SimulatedExperiment:
    counts: pd.DataFrame  # genes x samples, integer counts
    metadata: pd.DataFrame  # one row per sample: sample, condition[, batch][, time]
    truth: pd.DataFrame  # per gene: base_mean, dispersion, and the true effects
    size_factors: pd.Series  # per sample, geometric mean 1


def simulate(seed=1, n_genes=2000, replicates=(4, 4), levels=("control", "treated"),
             de_fraction=0.1, lfc_range=(1.0, 3.0), depth_range=(0.5, 2.0), batch=False):
    """Only the second level differs from the first; any further levels match the first."""
    if len(replicates) != len(levels):
        raise ValueError("replicates and levels must have the same length")
    rng = np.random.default_rng(seed)

    base_mean = rng.lognormal(mean=np.log(200), sigma=1.5, size=n_genes)
    dispersion = (0.04 + 1.0 / base_mean) * rng.lognormal(0.0, 0.3, size=n_genes)
    is_de = np.zeros(n_genes, dtype=bool)
    is_de[rng.choice(n_genes, size=int(round(de_fraction * n_genes)), replace=False)] = True
    magnitude = rng.uniform(*lfc_range, size=n_genes) * rng.choice([-1.0, 1.0], size=n_genes)
    true_lfc = np.where(is_de, magnitude, 0.0)

    conditions = np.repeat(levels, replicates)
    samples = [f"{level}_{index + 1}" for level, count in zip(levels, replicates) for index in range(count)]
    size_factors = np.exp(rng.uniform(np.log(depth_range[0]), np.log(depth_range[1]), size=len(samples)))
    size_factors /= np.exp(np.mean(np.log(size_factors)))

    log2_effect = np.outer(true_lfc, conditions == levels[1])
    metadata = pd.DataFrame({"sample": samples, "condition": conditions})
    if batch:
        # Alternate batches within each condition so batch is not confounded.
        within = np.concatenate([np.arange(count) for count in replicates])
        metadata["batch"] = np.where(within % 2 == 0, "b1", "b2")
        batch_lfc = rng.normal(0.0, 0.5, size=n_genes)
        log2_effect = log2_effect + np.outer(batch_lfc, metadata["batch"].to_numpy() == "b2")

    mean = base_mean[:, None] * size_factors[None, :] * 2.0 ** log2_effect
    shape = 1.0 / dispersion[:, None]
    counts = rng.negative_binomial(shape, shape / (shape + mean))

    genes = [f"gene{index + 1:05d}" for index in range(n_genes)]
    return SimulatedExperiment(
        counts=pd.DataFrame(counts, index=pd.Index(genes, name="gene_id"), columns=samples),
        metadata=metadata,
        truth=pd.DataFrame({"base_mean": base_mean, "dispersion": dispersion,
                            "true_lfc": true_lfc, "is_de": is_de}, index=pd.Index(genes, name="gene_id")),
        size_factors=pd.Series(size_factors, index=samples, name="size_factor"),
    )


def simulate_time_course(seed=1, n_genes=2000, times=(0, 6, 24), levels=("control", "treated"), replicates=3,
                         time_fraction=0.15, interaction_fraction=0.1, condition_fraction=0.1,
                         lfc_range=(1.0, 2.5), depth_range=(0.5, 2.0)):
    """Counts over time points, with known truth for the time-course tests.

    - Time genes share one random time profile in every condition (parallel change).
    - Interaction genes change over time only in the second condition.
    - Condition genes differ by a constant amount between conditions at every
      time (no interaction), which the condition-by-time test must not call.
    Gene sets are disjoint. Times are written as numbers.
    """
    rng = np.random.default_rng(seed)
    base_mean = rng.lognormal(mean=np.log(200), sigma=1.5, size=n_genes)
    dispersion = (0.04 + 1.0 / base_mean) * rng.lognormal(0.0, 0.3, size=n_genes)

    order = rng.permutation(n_genes)
    sizes = [int(round(fraction * n_genes)) for fraction in (time_fraction, interaction_fraction, condition_fraction)]
    kinds = np.full(n_genes, "null", dtype=object)
    start = 0
    for kind, size in zip(("time", "interaction", "condition"), sizes):
        kinds[order[start:start + size]] = kind
        start += size

    def profile():
        # No change at the first time point; at least one later time changes strongly.
        values = rng.uniform(*lfc_range, size=len(times) - 1) * rng.choice([-1.0, 1.0], size=len(times) - 1)
        values[rng.random(len(times) - 1) < 0.3] = 0.0
        if not np.any(values):
            values[rng.integers(len(values))] = rng.uniform(*lfc_range) * rng.choice([-1.0, 1.0])
        return np.concatenate([[0.0], values])

    shared = np.zeros((n_genes, len(times)))
    second_only = np.zeros((n_genes, len(times)))
    offset = np.zeros(n_genes)
    for gene in range(n_genes):
        if kinds[gene] == "time":
            shared[gene] = profile()
        elif kinds[gene] == "interaction":
            second_only[gene] = profile()
        elif kinds[gene] == "condition":
            offset[gene] = rng.uniform(*lfc_range) * rng.choice([-1.0, 1.0])

    samples, sample_levels, sample_times = [], [], []
    for level in levels:
        for time in times:
            for replicate in range(replicates):
                samples.append(f"{level}_t{time}_{replicate + 1}")
                sample_levels.append(level)
                sample_times.append(time)
    time_index = np.array([times.index(time) for time in sample_times])
    is_second = np.array([level == levels[1] for level in sample_levels])
    size_factors = np.exp(rng.uniform(np.log(depth_range[0]), np.log(depth_range[1]), size=len(samples)))
    size_factors /= np.exp(np.mean(np.log(size_factors)))

    log2_effect = shared[:, time_index] + second_only[:, time_index] * is_second + np.outer(offset, is_second)
    mean = base_mean[:, None] * size_factors[None, :] * 2.0 ** log2_effect
    shape = 1.0 / dispersion[:, None]
    counts = rng.negative_binomial(shape, shape / (shape + mean))

    genes = [f"gene{index + 1:05d}" for index in range(n_genes)]
    truth = pd.DataFrame({"base_mean": base_mean, "dispersion": dispersion, "kind": kinds}, index=pd.Index(genes, name="gene_id"))
    for column, time in enumerate(times):
        truth[f"reference_lfc_at_{time}"] = shared[:, column]
        truth[f"test_vs_reference_lfc_at_{time}"] = second_only[:, column] + offset
    return SimulatedExperiment(
        counts=pd.DataFrame(counts, index=pd.Index(genes, name="gene_id"), columns=samples),
        metadata=pd.DataFrame({"sample": samples, "condition": sample_levels, "time": sample_times}),
        truth=truth,
        size_factors=pd.Series(size_factors, index=samples, name="size_factor"),
    )


def planted_groups(truth):
    """{(term, description): genes that truly share a response}, used to plant enrichment."""
    if "true_lfc" in truth.columns:
        return {("ko99001", "Simulated pathway induced in treated"): truth.index[truth["true_lfc"] > 0],
                ("ko99002", "Simulated pathway repressed in treated"): truth.index[truth["true_lfc"] < 0]}
    times = [column.rsplit("_", 1)[1] for column in truth.columns if column.startswith("reference_lfc_at_")]
    early, late = times[1], times[-1]
    rises = (truth["kind"] == "time") & (truth[f"reference_lfc_at_{early}"] > 0)
    falls = (truth["kind"] == "interaction") & (truth[f"test_vs_reference_lfc_at_{late}"] < 0)
    return {("ko99001", f"Simulated pathway rising by {early} h"): truth.index[rises],
            ("ko99002", f"Simulated pathway falling by {late} h in the second condition only"): truth.index[falls]}


def simulate_annotations(experiment, seed=1, background_terms=40, coverage=0.85, planted_size=30, planted_share=0.7):
    """A long gene annotation table (gene_id, source, term, description) with known enrichment.

    Source "KEGG": random background pathways of 5 to 80 genes, plus planted
    pathways made mostly (planted_share) of genes with one true response.
    Source "COG": one functional category per annotated gene, with category X
    over-represented among the genes of the first planted group. Some genes
    have no annotation in each source.
    """
    rng = np.random.default_rng(seed)
    genes = experiment.truth.index.to_numpy()
    rows = []
    annotated = genes[rng.random(len(genes)) < coverage]
    for index in range(background_terms):
        members = rng.choice(annotated, size=int(rng.integers(5, 81)), replace=False)
        rows += [(gene, "KEGG", f"ko{90000 + index:05d}", f"Simulated pathway {index + 1}") for gene in members]
    groups = planted_groups(experiment.truth)
    for (term, description), group in groups.items():
        group = np.intersect1d(group, annotated)
        planted = rng.choice(group, size=min(len(group), int(round(planted_size * planted_share))), replace=False)
        others = rng.choice(np.setdiff1d(annotated, group), size=planted_size - len(planted), replace=False)
        rows += [(gene, "KEGG", term, description) for gene in np.concatenate([planted, others])]

    categories = list("CEGJKLMOPT")
    first_group = set(next(iter(groups.values())))
    for gene in genes[rng.random(len(genes)) < 0.9]:
        # X: half of the first planted group, plus 3% of all other genes as background.
        if rng.random() < (0.5 if gene in first_group else 0.03):
            rows.append((gene, "COG", "X", "Simulated stress response"))
        else:
            category = categories[rng.integers(len(categories))]
            rows.append((gene, "COG", category, f"COG category {category}"))
    table = pd.DataFrame(rows, columns=["gene_id", "source", "term", "description"])
    return table.sort_values(["gene_id", "source", "term"], kind="stable").reset_index(drop=True)


def write_inputs(experiment, directory, counts_name="counts.tsv", metadata_name="sample_metadata.tsv"):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    separator = "," if counts_name.endswith(".csv") else "\t"
    experiment.counts.to_csv(directory / counts_name, sep=separator)
    experiment.metadata.to_csv(directory / metadata_name, sep="\t", index=False)
    return directory / counts_name, directory / metadata_name


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output_dir")
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--time-course", action="store_true",
                        help="write timecourse_counts.tsv and timecourse_sample_metadata.tsv (two conditions, times 0, 6, 24)")
    parser.add_argument("--annotations", action="store_true",
                        help="also write annotations.tsv (or timecourse_annotations.tsv) with known enrichment")
    arguments = parser.parse_args()
    if arguments.time_course:
        experiment = simulate_time_course(seed=arguments.seed)
        write_inputs(experiment, arguments.output_dir,
                     counts_name="timecourse_counts.tsv", metadata_name="timecourse_sample_metadata.tsv")
        annotations_name = "timecourse_annotations.tsv"
    else:
        experiment = simulate(seed=arguments.seed)
        write_inputs(experiment, arguments.output_dir)
        annotations_name = "annotations.tsv"
    if arguments.annotations:
        simulate_annotations(experiment, seed=arguments.seed).to_csv(
            Path(arguments.output_dir) / annotations_name, sep="\t", index=False)
