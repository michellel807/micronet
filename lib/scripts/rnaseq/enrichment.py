"""Functional enrichment of gene sets with Fisher's exact test.

Usage:
    python enrichment.py RESULTS_DIR --annotations PATH

Asks, for each gene set and each annotation term: does the set contain more
genes with this term than expected by chance among the genes that could have
been in it? The gene sets are the significant genes higher and lower in the
test condition (two-condition runs) or each gene cluster (time courses; all
significant genes if they were not clustered).

The annotation table (TSV or CSV with a header) needs columns gene_id and
term; description and source are optional. A term cell may list several terms
separated by ";". Each source (for example GO, KEGG, COG) is tested and
corrected for multiple testing separately.

For one source, the universe is the genes DESeq2 tested that have at least one
annotation in that source. With N universe genes, K of them with the term, n
of them in the set and k in both, the p-value is the one-sided Fisher's exact
test P(X >= k) for X ~ hypergeometric(N, K, n). Terms with 3 to 500 universe
genes are tested; p-values are adjusted with Benjamini-Hochberg within each
gene set and source.

Writes enrichment_results.tsv (every tested term) and
enrichment_significant.tsv and adds an "enrichment" section to manifest.json.
No usable gene set or no matching annotation is not an error: the manifest
records why nothing was tested.
"""
import argparse
import json
import os
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import false_discovery_control, hypergeom

MIN_TERM_GENES = 3
MAX_TERM_GENES = 500
MIN_SET_GENES = 3
DEFAULT_SOURCE = "annotation"
OUTPUTS = {"enrichment_results": "enrichment_results.tsv", "enrichment_significant": "enrichment_significant.tsv"}
COLUMNS = ["gene_set", "source", "term", "description", "set_genes_with_term", "set_genes", "term_genes",
           "universe_genes", "expected", "fold_enrichment", "pvalue", "padj", "significant", "genes"]


class AnnotationError(ValueError):
    pass


def read_annotations(path):
    """Long table of unique (source, gene_id, term) rows, with each term's description."""
    path = Path(path)
    separator = "," if path.suffix.lower() == ".csv" else "\t"
    table = pd.read_csv(path, sep=separator, dtype=str, keep_default_na=False)
    table.columns = [str(column).strip().lower() for column in table.columns]
    missing = [column for column in ("gene_id", "term") if column not in table.columns]
    if missing:
        raise AnnotationError(f"The annotation table needs the column(s) {', '.join(missing)}.")
    blank = pd.Series("", index=table.index)
    source = table["source"].str.strip() if "source" in table.columns else blank
    table = table.assign(
        gene_id=table["gene_id"].str.strip(),
        source=source.replace("", DEFAULT_SOURCE),
        description=table["description"].str.strip() if "description" in table.columns else blank,
        term=table["term"].str.split(";"),
    ).explode("term")
    table["term"] = table["term"].str.strip()
    table = table[(table["gene_id"] != "") & (table["term"] != "")]
    described = table[table["description"] != ""].drop_duplicates(["source", "term"]).set_index(["source", "term"])["description"]
    unique = table.drop_duplicates(["source", "gene_id", "term"])[["source", "gene_id", "term"]].reset_index(drop=True)
    descriptions = [described.get((source, term), "") for source, term in zip(unique["source"], unique["term"])]
    return unique.assign(description=descriptions)


def gene_sets(manifest, results, clusters=None):
    """{name: [genes]} in report order."""
    significant = results[results["significant"]]
    if manifest["experiment_type"] == "two_condition":
        test = manifest["contrast"]["test_level"]
        change = significant["log2FoldChange"]
        return {f"higher in {test}": list(significant.index[change > 0]),
                f"lower in {test}": list(significant.index[change < 0])}
    if clusters is not None and (manifest.get("clustering") or {}).get("status") == "completed":
        return {f"cluster {number}": list(clusters.loc[clusters["cluster"] == number, "gene_id"])
                for number in sorted(clusters["cluster"].unique())}
    return {"all significant genes": list(significant.index)}


def enrich(set_genes, term_genes, universe, descriptions, alpha):
    """Test one gene set against one source's terms. term_genes: {term: set of universe genes}."""
    members = set(set_genes) & universe
    terms = [term for term, genes in term_genes.items() if MIN_TERM_GENES <= len(genes) <= MAX_TERM_GENES]
    if not terms:
        return pd.DataFrame(columns=COLUMNS[1:])
    overlap = [sorted(members & term_genes[term]) for term in terms]
    k = np.array([len(genes) for genes in overlap])
    big_k = np.array([len(term_genes[term]) for term in terms])
    n, total = len(members), len(universe)
    pvalue = hypergeom.sf(k - 1, total, big_k, n)
    padj = false_discovery_control(pvalue, method="bh")
    expected = n * big_k / total
    return pd.DataFrame({
        "term": terms, "description": [descriptions.get(term, "") for term in terms],
        "set_genes_with_term": k, "set_genes": n, "term_genes": big_k, "universe_genes": total,
        "expected": expected, "fold_enrichment": k / expected, "pvalue": pvalue, "padj": padj,
        "significant": padj < alpha, "genes": [";".join(genes) for genes in overlap],
    })


def analyze(manifest, results, annotations, clusters=None):
    """Returns (results table, manifest summary)."""
    alpha = float(manifest["parameters"]["alpha"])
    tested = set(results.index)
    sets = gene_sets(manifest, results, clusters)
    sources, tables, skipped = {}, [], []
    for source, rows in annotations.groupby("source", sort=False):
        rows = rows[rows["gene_id"].isin(tested)]
        universe = set(rows["gene_id"])
        term_genes = rows.groupby("term")["gene_id"].agg(set).to_dict()
        descriptions = rows.drop_duplicates("term").set_index("term")["description"].to_dict()
        sources[source] = {"tested_genes": len(tested), "annotated_tested_genes": len(universe),
                           "coverage": round(len(universe) / len(tested), 4) if tested else 0.0,
                           "terms_tested": sum(MIN_TERM_GENES <= len(genes) <= MAX_TERM_GENES for genes in term_genes.values())}
        for name, genes in sets.items():
            annotated = len(set(genes) & universe)
            if annotated < MIN_SET_GENES:
                skipped.append({"gene_set": name, "source": source,
                                "reason": f"{annotated} of its {len(genes)} genes have {source} annotations; at least {MIN_SET_GENES} are needed"})
                continue
            table = enrich(genes, term_genes, universe, descriptions, alpha)
            if len(table):
                tables.append(table.assign(gene_set=name, source=source))

    summary = {"method": "One-sided Fisher's exact test (hypergeometric) per term, Benjamini-Hochberg within each gene set and source",
               "alpha": alpha, "term_size_limits": [MIN_TERM_GENES, MAX_TERM_GENES],
               "gene_sets": [{"name": name, "genes": len(genes)} for name, genes in sets.items()],
               "sources": sources, "skipped": skipped}
    if not any(source["annotated_tested_genes"] for source in sources.values()):
        return None, {"status": "skipped", "reason": "None of the annotated gene IDs are among the genes DESeq2 tested."}
    if not tables:
        reason = ("No gene set had enough annotated genes to test." if skipped
                  else f"No annotation term has {MIN_TERM_GENES} to {MAX_TERM_GENES} tested genes.")
        return None, {"status": "skipped", "reason": reason, **summary}
    table = pd.concat(tables, ignore_index=True)[COLUMNS]
    order = {name: index for index, name in enumerate(sets)}
    table = table.sort_values(["gene_set", "source", "padj", "pvalue", "term"], kind="stable",
                              key=lambda column: column.map(order) if column.name == "gene_set" else column)
    counts = table[table["significant"]].groupby(["gene_set", "source"]).size()
    summary["significant_terms"] = {name: {source: int(counts.get((name, source), 0)) for source in sources} for name in sets}
    return table.reset_index(drop=True), {"status": "completed", **summary}


def write_json_atomically(data, path):
    partial = path.with_name(path.name + ".partial")
    partial.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(partial, path)


def main(results_dir, annotations_path):
    directory = Path(results_dir)
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("status") != "completed":
        raise SystemExit("The differential expression results are incomplete; nothing was tested for enrichment.")
    for key, name in OUTPUTS.items():
        manifest["outputs"].pop(key, None)
        (directory / name).unlink(missing_ok=True)

    try:
        annotations = read_annotations(annotations_path)
    except AnnotationError as error:
        raise SystemExit(str(error))
    results = pd.read_csv(directory / manifest["outputs"]["results"], sep="\t", index_col="gene_id")
    results.index = results.index.astype(str)
    results["significant"] = results["significant"].astype(str).str.upper().eq("TRUE")
    clusters = None
    if "gene_clusters" in manifest["outputs"]:
        clusters = pd.read_csv(directory / manifest["outputs"]["gene_clusters"], sep="\t", dtype={"gene_id": str})
    table, summary = analyze(manifest, results, annotations, clusters)
    summary["annotation_file"] = Path(annotations_path).name
    if table is not None:
        table.to_csv(directory / OUTPUTS["enrichment_results"], sep="\t", index=False, na_rep="NA")
        table[table["significant"]].to_csv(directory / OUTPUTS["enrichment_significant"], sep="\t", index=False, na_rep="NA")
        manifest["outputs"].update(OUTPUTS)
    manifest["enrichment"] = summary
    write_json_atomically(manifest, manifest_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("results_dir")
    parser.add_argument("--annotations", required=True)
    arguments = parser.parse_args()
    main(arguments.results_dir, arguments.annotations)
