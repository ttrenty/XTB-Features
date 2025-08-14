import csv
import os
import glob
import subprocess

import click
from morfeus import read_xyz, XTB, LocalForce
import numpy as np
import pandas as pd

# --- Setup Configuration ---
BASH_SCRIPT_PATH = "process_xtb/process_molecule.sh"

# --- User Configuration ---

# Input files
XYZ_MOLECULES_DIR = ["bse49/Geometries/Existing", "bse49/Geometries/Hypothetical"]

# Output files
DEFAULT_OUTPUT_DIR = "data/BSE/xtb_reps/"
COMBINED_XTB_FEATURES_PATH = "data/BSE/xtb_features_combined_test.csv"


def get_all_xyz_files():
    """Gathers and sorts all .xyz file paths."""
    all_files = []
    for directory in XYZ_MOLECULES_DIR:
        if os.path.isdir(directory):
            for filename in os.listdir(directory):
                if filename.endswith(".xyz"):
                    all_files.append(os.path.join(directory, filename))
        else:
            print(f"Warning: Directory not found: {directory}")

    all_files.sort()
    return all_files


@click.group()
def cli():
    """A tool to manage XTB feature generation for the BSE dataset."""
    pass


@cli.command()
def size():
    """Prints the total number of molecules in the dataset."""
    all_files = get_all_xyz_files()
    print(len(all_files))


@cli.command()
@click.option(
    "--start_index", type=int, required=True, help="Starting index for this batch."
)
@click.option(
    "--batch_size",
    type=int,
    default=50,
    help="Number of molecules to process in this batch.",
)
@click.option("--output_dir", type=click.Path(), default=DEFAULT_OUTPUT_DIR)
def generate_batch(start_index, batch_size, output_dir):
    """
    Generates XTB features for a batch of molecules by calling an external bash script.
    """
    all_xyz_files = get_all_xyz_files()
    dataset_size = len(all_xyz_files)
    end_index = min(start_index + batch_size, dataset_size)

    print(
        f"Processing molecules {start_index} to {end_index - 1} out of {dataset_size}"
    )
    os.makedirs(output_dir, exist_ok=True)

    for index in range(start_index, end_index):
        xyz_file_path = all_xyz_files[index]
        mol_name = os.path.splitext(os.path.basename(xyz_file_path))[0]
        output_file = os.path.join(output_dir, f"{mol_name}.csv")

        if os.path.exists(output_file):
            print(
                f"[{index}/{dataset_size}] Skipping already processed molecule: {mol_name}"
            )
            continue

        print(f"[{index}/{dataset_size}] Running xtb for {mol_name}...")
        # --- Step 1: Run the Bash script to get xtb features ---
        try:
            command = ["bash", BASH_SCRIPT_PATH, xyz_file_path, output_file]
            # print(f"[{index}/{dataset_size}] Running xtb via bash for {mol_name}...")

            # Execute the command. check=True will raise an error on failure.
            subprocess.run(command, check=True, capture_output=True, text=True)

        except subprocess.CalledProcessError as e:
            # If the bash script fails, print the error and skip to the next molecule.
            print(
                f"Error: Bash script failed for {xyz_file_path} with exit code {e.returncode}"
            )
            print(f"--- BASH SCRIPT STDOUT ---\n{e.stdout}")
            print(f"--- BASH SCRIPT STDERR ---\n{e.stderr}")
            # Clean up the potentially empty/incomplete CSV file
            if os.path.exists(output_file):
                os.remove(output_file)
            continue  # Move to the next molecule
        except Exception as e:
            print(
                f"An unexpected error occurred during subprocess call for {xyz_file_path}: {e}"
            )
            continue

        # --- Step 2: Run Morfeus and merge the results ---
        try:
            # print(
            #     f"[{index}/{dataset_size}] Calculating morfeus features for {mol_name}..."
            # )
            elements, coordinates = read_xyz(xyz_file_path)
            xtb_morfeus = XTB(elements, coordinates)

            # Calculate morfeus features
            ip = xtb_morfeus.get_ip(corrected=True)
            ea = xtb_morfeus.get_ea(corrected=True)
            electrophilicity = xtb_morfeus.get_global_descriptor(
                "electrophilicity", corrected=True
            )
            electrofugality = xtb_morfeus.get_global_descriptor(
                "electrofugality", corrected=True
            )
            nucleofugality = xtb_morfeus.get_global_descriptor(
                "nucleofugality", corrected=True
            )

            morfeus_header = [
                "ip",
                "ea",
                "electrophilicity",
                "electrofugality",
                "nucleofugality",
            ]
            morfeus_data = [ip, ea, electrophilicity, electrofugality, nucleofugality]

            # --- Step 3: Read existing data, combine, and write back ---
            # Read the header and data row created by the bash script
            with open(output_file, "r", newline="") as f_in:
                reader = csv.reader(f_in)
                existing_header = next(reader)
                existing_data_row = next(reader)

            # Combine headers and data
            combined_header = existing_header + morfeus_header
            combined_data_row = existing_data_row + morfeus_data

            # Write the fully combined data back to the file, overwriting it
            with open(output_file, "w", newline="") as f_out:
                writer = csv.writer(f_out)
                writer.writerow(combined_header)
                writer.writerow(combined_data_row)

            print(
                f"[{index}/{dataset_size}] Successfully combined features for: {mol_name}"
            )

        except Exception as e:
            # If morfeus or the file merging fails, report the error and clean up.
            print(
                f"Error: Morfeus calculation or CSV merge failed for {xyz_file_path}: {e}"
            )
            # Remove the partial file from the bash script to signal it needs reprocessing
            if os.path.exists(output_file):
                os.remove(output_file)
            continue  # Move to the next molecule


# The combine_xtb function should work as-is because the bash script now
# produces CSVs with the 'mol_name' column.
@cli.command()
@click.option(
    "--input-dir",
    default=DEFAULT_OUTPUT_DIR,
    help="Directory containing individual XTB feature CSV files.",
)
@click.option(
    "--output-file",
    default=COMBINED_XTB_FEATURES_PATH,
    help="Path to save the combined CSV file.",
)
def combine_xtb(input_dir: str, output_file: str):
    """Combines all individual XTB .csv files into one master file."""
    print(f"Searching for CSV files in: {input_dir}")
    csv_files = glob.glob(os.path.join(input_dir, "*.csv"))

    if not csv_files:
        print(f"Error: No .csv files found in {input_dir}. Nothing to combine.")
        return

    print(f"Found {len(csv_files)} files to combine.")
    df_list = [pd.read_csv(f) for f in csv_files]
    combined_df = pd.concat(df_list, ignore_index=True)
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    combined_df.to_csv(output_file, index=False)
    print(f"Successfully combined {len(combined_df)} entries into {output_file}")


if __name__ == "__main__":
    cli()
