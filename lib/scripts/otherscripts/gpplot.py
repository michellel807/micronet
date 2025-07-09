import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import os
import sys

def plot_gp_data(derived_path):
    data = pd.read_csv(os.path.join(derived_path, "plot_gp_data.txt"), sep='\t', encoding='utf-8')
    col = data.columns[1]
    data = data[[col, 'Time', 'mu', 'Sigma']]
    conditions = data[col].unique()

    # Set up the plot
    plt.figure(figsize=(10, 6))

    # Loop through each condition
    for condition in conditions:
        # Filter the data for this condition
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

    # Final touches
    plt.xlabel('Time')
    plt.ylabel('Predicted OD')
    plt.title('Predicted OD with 95% CI')
    plt.legend()
    plt.grid(True)

    # Save the plot
    plot_path = os.path.join(derived_path, "gp_plot.pdf")
    plt.savefig(plot_path)

if __name__ == "__main__":
    # Check if two filenames are provided as command-line arguments
    if len(sys.argv) != 2:
        print("Usage: python gpplot.py derived_path")
        sys.exit(1)

    # Get the filenames from command-line arguments
    derived_path = sys.argv[1]

    # Call the function and get the result
    plot_gp_data(derived_path)
