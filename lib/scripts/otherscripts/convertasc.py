import sys

def convert_asc_to_tab_delimited(input_file_path, output_file_path):
    try:
        with open(input_file_path, 'r', encoding='utf-16') as input_file:
            content = input_file.read()

        with open(output_file_path, 'w', encoding='utf-8') as output_file:
            output_file.write(content)

        print("Conversion successful!")
    except Exception as e:
        print("An error occurred during conversion:", e)
        
if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python convertasc.py <input_file_path> <output_file_path>")
    else:
        input_file_path = sys.argv[1]
        output_file_path = sys.argv[2]

        convert_asc_to_tab_delimited(input_file_path, output_file_path)