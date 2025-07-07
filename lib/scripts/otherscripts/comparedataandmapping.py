import sys
import pandas as pd

def compare_files(data_file, mapping_file):
    try:
        mapping_file = pd.read_csv(mapping_file,sep="\t",header=None)
        
        data_file = pd.read_csv(data_file,sep="\t",header=None)
        
        mapping_file.reset_index(drop=True, inplace=True)
        data_file.reset_index(drop=True, inplace=True)
        
        if len(mapping_file) != len(data_file):
            return False

        if len(mapping_file) == len(data_file):
            return True

    except Exception as e:
        return False
        
        
if __name__ == "__main__":
    # Check if two filenames are provided as command-line arguments
    if len(sys.argv) != 3:
        print("Usage: python comparefiles.py fileA fileB")
        sys.exit(1)

    # Get the filenames from command-line arguments
    data_file = sys.argv[1]
    mapping_file = sys.argv[2]

    # Call the comparison function and get the result
    success = compare_files(data_file, mapping_file)
    if success:
        sys.exit(0)  # success
    else:
        sys.exit(1)  # failure
    
        