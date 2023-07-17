ximport sys
import pandas as pd

# Check if the input file argument is provided
if len(sys.argv) < 2:
    print("Please provide the input file name as an argument.")
    sys.exit(1)

# Get the input file name from the command-line argument
input_file = sys.argv[1]

# Specify the columns to drop
columns_to_drop = ['OD_Baseline','OD_Min','OD_Max', 'OD_Emp_AUC', 'Fold_Change', 'OD_Offset', 
'auc_log', 'k_log', 'death_lin', 'death_log', 'gr', 'dr', 'lagP', 't_gr', 't_dr', 't_k', 'diauxie']

# Read the input file into a DataFrame
df = pd.read_csv(input_file, delimiter='\t')

# Drop the specified columns
df = df.drop(columns=columns_to_drop)
df = df.rename(columns={'auc_lin': 'AUC in units of OD', 'k_lin': 'Linear Carrying Capacity in units 
of OD', 'lagC': 'lag time', 'td': 'doubling time'})

# Create the output file name by removing the '.txt' extension from the input file
output_file = input_file[:-4] + "_modified.txt"

# Save the modified DataFrame to a new file
df.to_csv(output_file, sep='\t', index=False)

