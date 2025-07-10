#!/usr/bin/env python3
import argparse
import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import os
import sys


def main():
    parser = argparse.ArgumentParser(
        description="Generate a heatmap from a summary file."
    )
    parser.add_argument(
        "-i", "--input", required=True, help="Input summary file (tab-delimited)"
    )
    parser.add_argument(
        "-o", "--output", required=True, help="Output file path (without extension)"
    )
    parser.add_argument("-x", "--x", help="Column for X axis")
    parser.add_argument("-y", "--y", help="Column for Y axis")
    parser.add_argument("-v", "--value", help="Column for heatmap values")
    parser.add_argument("--title", default="Heatmap", help="Title for the heatmap")
    parser.add_argument(
        "--format", default="png", choices=["png", "jpg"], help="Output format"
    )
    parser.add_argument(
        "--list-v",
        action="store_true",
        help="List last 5 columns for V choices and exit",
    )
    parser.add_argument(
        "--list-x-y",
        action="store_true",
        help="List all columns for X/Y choices and exit",
    )
    args = parser.parse_args()

    # Read the data
    df = pd.read_csv(args.input, sep="\t")

    if args.list_v:
        print("Available value columns (last 5):", df.columns[-5:].tolist())
        sys.exit(0)
    if args.list_x_y:
        print("Available columns for X/Y:", df.columns.tolist())
        sys.exit(0)

    # Check columns
    if args.x not in df.columns or args.y not in df.columns:
        print("Available columns for X/Y:", df.columns.tolist())
        raise ValueError(f"Columns {args.x} or {args.y} not found in input file.")
    if args.value not in df.columns:
        print("Available value columns (last 5):", df.columns[-5:].tolist())
        raise ValueError(f"Column {args.value} not found in input file.")

    # Pivot the data
    heatmap_data = df.pivot_table(
        index=args.y, columns=args.x, values=args.value, aggfunc="mean"
    )

    # Plot
    plt.figure(figsize=(10, 8))
    sns.heatmap(heatmap_data, cmap="viridis", annot=True, fmt=".2f")
    title_with_value = f"{args.title} ({args.value})" if args.value else args.title
    plt.title(title_with_value)
    plt.tight_layout()

    # Save
    out_path = f"{args.output}.{args.format}"
    plt.savefig(out_path, format=args.format)
    print(f"Saved heatmap to {out_path}")


if __name__ == "__main__":
    main()
