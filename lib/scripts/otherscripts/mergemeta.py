import pandas as pd
import os
import sys

def merge_meta_files(data_path, mapping_path):
      meta_file = pd.read_csv(os.path.join(mapping_path, "meta.txt"), sep="\t", encoding="utf-8")
      meta_columns = meta_file.columns.tolist()

      def normalize_group(value):
          if pd.isna(value):
              return value
          text = str(value).strip()
          if text.isdigit():
              return f"G{int(text)}"
          return text

      for _, row in meta_file.iterrows():
          plate_id = row["Plate_ID"]
          mapping_file_path = os.path.join(mapping_path, f"{plate_id}.txt")

          if os.path.exists(mapping_file_path):
              mapping_file = pd.read_csv(mapping_file_path, sep="\t", encoding="utf-8")
              mapping_file[meta_columns[1:]] = row[meta_columns[1:]]

              if "Group" in mapping_file.columns:
                  mapping_file["Group"] = mapping_file["Group"].apply(normalize_group)

          else:
              data_file_path = os.path.join(data_path, f"{plate_id}.txt")
              if not os.path.exists(data_file_path):
                  print(f"Data file for plate {plate_id} does not exist. Skipping.")
                  continue

              data_file = pd.read_csv(data_file_path, sep="\t", encoding="utf-8")
              mapping_file = data_file.iloc[:, [0]].copy()
              mapping_file.columns = ["Well positions"]
              mapping_file[meta_columns] = row[meta_columns]

              if "Group" in mapping_file.columns:
                  mapping_file["Group"] = mapping_file["Group"].apply(normalize_group)

          mapping_file.to_csv(mapping_file_path, sep="\t", index=False, encoding="utf-8")
          print(f"Merged data saved to {mapping_file_path}")

      return "Meta files merged successfully."


if __name__ == "__main__":
    # Check if two filenames are provided as command-line arguments
    if len(sys.argv) != 3:
        print("Usage: python mergemeta.py data_path mapping_path")
        sys.exit(1)

    # Get the filenames from command-line arguments
    data_path = sys.argv[1]
    mapping_path = sys.argv[2]

    # Call the function and get the result
    result = merge_meta_files(data_path, mapping_path)

    # Print the result
    print(result)
