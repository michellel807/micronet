import pandas as pd
import os
import sys
import json
from collections import defaultdict

def load_pair_metadata(metadata_path):
      if not metadata_path or not os.path.exists(metadata_path):
          return []
      with open(metadata_path, "r", encoding="utf-8") as handle:
          payload = json.load(handle)
      pairs = payload.get("pairs", [])
      return sorted(pairs, key=lambda pair: int(pair.get("pair_index", 0)))


def build_plate_id_lookup(pair_metadata):
      lookup = defaultdict(list)
      for pair in pair_metadata:
          parsed_plate_id = pair.get("parsed_plate_id")
          pair_key = pair.get("pair_key")
          if parsed_plate_id and pair_key:
              lookup[str(parsed_plate_id)].append(str(pair_key))
      return lookup


def resolve_pair_key(plate_id, data_path, pair_lookup, pair_order, consumed_pairs):
      plate_key = str(plate_id)
      for pair_key in pair_lookup.get(plate_key, []):
          if pair_key not in consumed_pairs:
              consumed_pairs.add(pair_key)
              return pair_key

      if os.path.exists(os.path.join(data_path, f"{plate_key}.txt")):
          consumed_pairs.add(plate_key)
          return plate_key

      for pair_key in pair_order:
          if pair_key not in consumed_pairs:
              consumed_pairs.add(pair_key)
              return pair_key

      return None


def merge_meta_files(data_path, mapping_path, metadata_path=None):
      meta_file = pd.read_csv(os.path.join(mapping_path, "meta.txt"), sep="\t", encoding="utf-8")
      meta_columns = meta_file.columns.tolist()
      pair_metadata = load_pair_metadata(metadata_path)
      pair_lookup = build_plate_id_lookup(pair_metadata)
      pair_order = [str(pair.get("pair_key")) for pair in pair_metadata if pair.get("pair_key")]
      consumed_pairs = set()

      def normalize_group(value):
          if pd.isna(value):
              return value
          text = str(value).strip()
          if text.isdigit():
              return f"G{int(text)}"
          return text

      for _, row in meta_file.iterrows():
          original_plate_id = row["Plate_ID"]
          pair_key = resolve_pair_key(original_plate_id, data_path, pair_lookup, pair_order, consumed_pairs)
          if pair_key is None:
              print(f"No matching pair found for plate {original_plate_id}. Skipping.")
              continue
          mapping_file_path = os.path.join(mapping_path, f"{pair_key}.txt")

          if os.path.exists(mapping_file_path):
              mapping_file = pd.read_csv(mapping_file_path, sep="\t", encoding="utf-8")
              mapping_file[meta_columns[1:]] = row[meta_columns[1:]]
              mapping_file["Plate_ID"] = pair_key
              if "Original_Plate_ID" in mapping_file.columns:
                  mapping_file["Original_Plate_ID"] = original_plate_id

              if "Group" in mapping_file.columns:
                  mapping_file["Group"] = mapping_file["Group"].apply(normalize_group)

          else:
              data_file_path = os.path.join(data_path, f"{pair_key}.txt")
              if not os.path.exists(data_file_path):
                  print(f"Data file for pair {pair_key} does not exist. Skipping.")
                  continue

              data_file = pd.read_csv(data_file_path, sep="\t", encoding="utf-8")
              mapping_file = data_file.iloc[:, [0]].copy()
              mapping_file.columns = ["Well positions"]
              mapping_file[meta_columns[1:]] = row[meta_columns[1:]]
              mapping_file["Plate_ID"] = pair_key
              mapping_file["Original_Plate_ID"] = original_plate_id

              if "Group" in mapping_file.columns:
                  mapping_file["Group"] = mapping_file["Group"].apply(normalize_group)

          mapping_file.to_csv(mapping_file_path, sep="\t", index=False, encoding="utf-8")
          print(f"Merged data saved to {mapping_file_path}")

      return "Meta files merged successfully."


if __name__ == "__main__":
    # Check if file path arguments are provided
    if len(sys.argv) not in (3, 4):
        print("Usage: python mergemeta.py data_path mapping_path [metadata_path]")
        sys.exit(1)

    # Get the filenames from command-line arguments
    data_path = sys.argv[1]
    mapping_path = sys.argv[2]
    metadata_path = sys.argv[3] if len(sys.argv) == 4 else None

    # Call the function and get the result
    result = merge_meta_files(data_path, mapping_path, metadata_path)

    # Print the result
    print(result)
