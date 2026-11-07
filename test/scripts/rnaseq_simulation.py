"""Negative-binomial RNA-seq counts with known truth, for testing the DESeq2 stage.

Counts follow the model DESeq2 assumes:
    K_ij ~ NB(mean = s_j * q_i * 2^(beta_i * x_j), dispersion = alpha_i)
with per-sample size factors s_j, per-gene base means q_i, a mean-dependent
dispersion trend, and true log2 fold changes beta_i for a known set of genes.

Running this file writes example inputs:
    python test/scripts/rnaseq_simulation.py lib/examplefiles/rnaseq --seed 2026
"""
import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


@dataclass
class SimulatedExperiment:
    counts: pd.DataFrame  # genes x samples, integer counts
    metadata: pd.DataFrame  # one row per sample: sample, condition[, batch]
    truth: pd.DataFrame  # per gene: base_mean, dispersion, true_lfc, is_de
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
    arguments = parser.parse_args()
    write_inputs(simulate(seed=arguments.seed), arguments.output_dir)
