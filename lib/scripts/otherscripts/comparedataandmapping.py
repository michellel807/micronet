import sys
import re
import csv
import json

WELL_ID_PATTERN = re.compile(r"^[A-Za-z]\d+$")


def count_well_rows(file_path):
    count = 0
    with open(file_path, "r", encoding="utf-8", errors="replace", newline="") as handle:
        reader = csv.reader(handle, delimiter="\t")
        for row in reader:
            if not row:
                continue
            first_col = row[0].strip().lstrip("\ufeff")
            if WELL_ID_PATTERN.match(first_col):
                count += 1
    return count

def compare_files(data_file, mapping_file):
    data_well_count = count_well_rows(data_file)
    mapping_well_count = count_well_rows(mapping_file)
    return {
        "data_well_count": data_well_count,
        "mapping_well_count": mapping_well_count,
        "counts_match": data_well_count == mapping_well_count,
    }


if __name__ == "__main__":
    emit_json = "--json" in sys.argv
    count_only = "--count-only" in sys.argv
    args = [arg for arg in sys.argv[1:] if arg not in ("--json", "--count-only")]

    expected_args = 1 if count_only else 2
    if len(args) != expected_args:
        print("Usage: python comparedataandmapping.py [--json] [--count-only] fileA [fileB]")
        sys.exit(1)

    try:
        if count_only:
            result = {"data_well_count": count_well_rows(args[0])}
        else:
            result = compare_files(args[0], args[1])

        if emit_json:
            print(json.dumps(result), flush=True)
        elif count_only:
            print(f"DATA WELL COUNT = {result['data_well_count']}", flush=True)
        else:
            print(f"DATA WELL COUNT = {result['data_well_count']}", flush=True)
            print(f"MAPPING WELL COUNT = {result['mapping_well_count']}", flush=True)
            print(f"COMPARE RESULT = {result['counts_match']}")
        sys.exit(0 if count_only or result["counts_match"] else 1)
    except Exception as e:
        if emit_json:
            print(json.dumps({"error": str(e)}), flush=True)
        sys.exit(1)
    
        
