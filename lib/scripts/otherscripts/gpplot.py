import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import os
import sys

# Font sizes for Gaussian process plots. The RNA-seq cluster curves
# (lib/scripts/rnaseq/plot_results.py) use this style and the helpers below,
# so both kinds of GP plot look the same.
STYLE = {
    'axes.titlesize': 16,
    'axes.labelsize': 14,
    'legend.fontsize': 12
}
FIGURE_SIZE = (10, 6)
Z95 = 1.96


def draw_gp_curve(axes, time, mean, std_dev, label):
    """A GP mean line labeled '<label> Mean' with its 95% confidence band."""
    mean, std_dev = np.asarray(mean), np.asarray(std_dev)
    line, = axes.plot(time, mean, label=f'{label} Mean')
    axes.fill_between(time, mean - Z95 * std_dev, mean + Z95 * std_dev, alpha=0.2)
    return line


def finish_gp_plot(axes, title, ylabel, xlabel='Time'):
    axes.set_xlabel(xlabel)
    axes.set_ylabel(ylabel)
    axes.set_title(title)
    axes.legend()
    axes.grid(True)


def plot_gp_data(derived_path, subset_name=None, pool_columns=None):
    with plt.rc_context(STYLE):
        _plot_gp_data(derived_path, subset_name, pool_columns)


def _plot_gp_data(derived_path, subset_name, pool_columns):
    data = pd.read_csv(os.path.join(derived_path, "plot_gp_data.txt"), sep='\t', encoding='utf-8')
    print("COLUMNS:")
    print(data.columns.tolist())

    # Set up the plot
    plt.figure(figsize=FIGURE_SIZE)
    axes = plt.gca()
    if 'mu' in data.columns and 'Sigma' in data.columns:
        #pooled option
        columns = pool_columns or [data.columns[1]]
        missing = [column for column in columns if column not in data.columns]
        if missing:
            raise ValueError(f"Grouping columns missing from GP output: {', '.join(missing)}")
        for group, cond_data in data.groupby(columns, sort=False, dropna=False):
            group = group if isinstance(group, tuple) else (group,)
            condition = ", ".join(f"{column}: {value}" for column, value in zip(columns, group))
            cond_data = cond_data.sort_values(by='Time')
            # Mean line and 95% confidence interval
            draw_gp_curve(axes, cond_data['Time'].values, cond_data['mu'].values,
                          np.sqrt(cond_data['Sigma'].values), condition)
    else:
    # non-pooled option
        for sample in data['Sample_ID'].unique():
            cond_data = data[data['Sample_ID'] == sample].sort_values(by='Time')
            plt.plot (cond_data['Time'], cond_data['OD_Fit'], label=sample)
    # Final touches
    if subset_name and subset_name != ':':
        title = f'Gaussian Process Plot with Subset {subset_name}'
    else:
        title = 'Gaussian Process Plot'
    finish_gp_plot(axes, title, 'Predicted OD')

    # Save the plot
    plot_path = os.path.join(derived_path, "gp_plot.pdf")
    plt.savefig(plot_path)

if __name__ == "__main__":
    # Check if two filenames are provided as command-line arguments
    if len(sys.argv) < 2:
        print("Usage: python gpplot.py derived_path subset_name")
        sys.exit(1)

    # Get the filenames from command-line arguments
    derived_path = sys.argv[1]
    subset_name = sys.argv[2] if len(sys.argv) > 2 else None

    # Call the function and get the result
    pool_columns = sys.argv[3].split(',') if len(sys.argv) > 3 and sys.argv[3] not in ('', 'None') else None
    plot_gp_data(derived_path, subset_name, pool_columns)
