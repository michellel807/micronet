import sys
import csv
import matplotlib.pyplot as plt
import os
import pandas as pd

def generate_plot(csv_path):
    data = pd.read_csv(csv_path)
    df = pd.DataFrame(data)
    X = list(df.iloc[:, 0])
    Y = list(df.iloc[:, 1])    
    plt.bar(X, Y)
    # Define the path where the plot image should be saved
    plot_path = os.path.join(os.path.dirname(csv_path), 'barplot.png')

    plt.savefig(plot_path)
    plt.close()

if __name__ == '__main__':
    csv_path = sys.argv[1]
    generate_plot(csv_path)

