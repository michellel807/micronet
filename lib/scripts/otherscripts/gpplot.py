import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import os
import sys

# Set global font sizes for all plots
plt.rcParams.update({
    'axes.titlesize': 16,
    'axes.labelsize': 14,
    'legend.fontsize': 12
})

def plot_gp_data(derived_path, subset_name=None):
    data = pd.read_csv(os.path.join(derived_path, "plot_gp_data.txt"), sep='\t', encoding='utf-8')
    print("COLUMNS:")
    print(data.columns.tolist())

    # Set up the plot
    plt.figure(figsize=(10, 6))
    if 'mu' in data.columns and 'Sigma' in data.columns:
        #pooled option
        col = data.columns[1]
        data = data[[col, 'Time', 'mu', 'Sigma']]
        conditions = data[col].unique()
        for condition in conditions:
            cond_data = data[data[col] == condition].sort_values(by='Time')
            # Extract values
            time = cond_data['Time'].values
            mean = cond_data['mu'].values
            std_dev = np.sqrt(cond_data['Sigma'].values)
            # Confidence interval (95%)
            z = 1.96
            lower = mean - z * std_dev
            upper = mean + z * std_dev
            # Plot mean line
            plt.plot(time, mean, label=f'{condition} Mean')
            # Plot confidence interval
            plt.fill_between(time, lower, upper, alpha=0.2)
            # Filter the data for this condition
    else:
    # non-pooled option
        for sample in data['Sample_ID'].unique():
            cond_data = data[data['Sample_ID'] == sample].sort_values(by='Time')
            plt.plot (cond_data['Time'], cond_data['OD_Fit'], label=sample)
    # Final touches
    plt.xlabel('Time')
    plt.ylabel('Predicted OD')
    if subset_name != ':':
        title = f'Gaussian Process Plot with Subset {subset_name}'
    else:
        title = 'Gaussian Process Plot'
    plt.title(title)
    plt.legend()
    plt.grid(True)

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
    plot_gp_data(derived_path, subset_name)
