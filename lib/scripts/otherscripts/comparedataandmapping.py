import sys
import pandas as pd

def compare_files(data_file, mapping_file):
    try:
        mapping_file = pd.read_csv(mapping_file,sep=",",header=None)
        
        data_file = pd.read_csv(data_file,sep=",",header=None)
        
        mapping_file = mapping_file.iloc[1:]
        mapping_file.reset_index(drop=True, inplace=True)
        data_file.reset_index(drop=True, inplace=True)

        
        if len(mapping_file) != len(data_file):
            return "Error: Number of rows in the two files is different."

        if len(mapping_file) == len(data_file):
            return "Files match"

    except Exception as e:
        return "Error: " + str(e)
        
        
if __name__ == "__main__":
    # Check if two filenames are provided as command-line arguments
    if len(sys.argv) != 3:
        print("Usage: python comparefiles.py fileA fileB")
        sys.exit(1)

    # Get the filenames from command-line arguments
    data_file = sys.argv[1]
    mapping_file = sys.argv[2]

    # Call the comparison function and get the result
    result = compare_files(data_file, mapping_file)

    # Print the result
    print(result)
    
        