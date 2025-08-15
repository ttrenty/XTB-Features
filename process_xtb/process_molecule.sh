#!/bin/bash

# A script to run xtb on a single .xyz file and save the parsed output
# to a specified .csv file. This script will exit with a specific error
# message if any value cannot be parsed.
#
# Usage: ./process_molecule.sh <input_xyz_file> <output_csv_file>

# --- Input Validation ---
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <input_xyz_file> <output_csv_file>"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="$2"

# --- Run Calculation ---
echo "Processing $INPUT_FILE..."
# Use stdbuf to ensure output is captured in real-time if needed
output=$(stdbuf -oL xtb "$INPUT_FILE" --hess --uhf 1)

if [ $? -ne 0 ]; then
    echo "Error: xtb command failed for $INPUT_FILE" >&2
    exit 1
fi

# --- Parse Output ---
mol_name=$(basename "$INPUT_FILE" .xyz)

# Request 1 & 6: Energies, Enthalpy, HOMO/LUMO in Eh
total_energy=$(echo "$output" | grep 'TOTAL ENERGY' | awk '{print $4}')
total_enthalpy=$(echo "$output" | grep 'TOTAL ENTHALPY' | awk '{print $4}')
total_free_energy=$(echo "$output" | grep 'TOTAL FREE ENERGY' | awk '{print $5}')
zpve=$(echo "$output" | grep 'zero point energy' | awk '{print $5}')
# Use head -n 1 to ensure only one value is captured if the pattern appears multiple times
homo_energy=$(echo "$output" | grep '(HOMO)' | head -n 1 | awk '{print $4}')
lumo_energy=$(echo "$output" | grep '(LUMO)' | head -n 1 | awk '{print $3}')

# Request 2: Thermodynamic properties
thermo_line=$(echo "$output" | grep -A 10 'temp. (K)  partition function' | grep 'TOT')
tot_enthalpy=$(echo "$thermo_line" | awk '{print $2}')
tot_heat_capacity=$(echo "$thermo_line" | awk '{print $3}')
tot_entropy=$(echo "$thermo_line" | awk '{print $4}')

# Request 5 & other properties: C6, C8, Polarizability, and Dipole
c6aa=$(echo "$output" | grep 'Mol. C6AA' | awk '{print $5}')
c8aa=$(echo "$output" | grep 'Mol. C8AA' | awk '{print $5}')
polarizability=$(echo "$output" | grep 'Mol. α(0) /au' | awk '{print $5}')
dipole=$(echo "$output" | grep -A 3 'molecular dipole:' | grep 'full:' | awk '{print $5}')

# Request 3: Vibrational frequencies (positive, non-zero)
vibr_freqs_list=$(echo "$output" | grep 'eigval :' | grep -v -- '-0.00' | grep -v ' 0.00' | sed 's/eigval ://g' | tr -s ' ' '\n' | sed '/^$/d' | grep -v '^-')

# Request 4: IR intensities
# This complex command extracts all IR intensity values, sorts them numerically in reverse order, and takes the top 3
ir_intensities_list=$(echo "$output" \
    | awk '/IR intensities/,/Raman intensities/' \
    | grep -v 'IR intensities' \
    | grep -v 'Raman' \
    | sed 's/.*://' \
    | tr -s ' ' '\n' \
    | sed '/^$/d' \
    | sed 's/[*][*]*/0/g' \
    | sort -nr)
# Get top 3, pad if missing
ir_max_1=$(echo "$ir_intensities_list" | sed -n '1p')
ir_max_2=$(echo "$ir_intensities_list" | sed -n '2p')
ir_max_3=$(echo "$ir_intensities_list" | sed -n '3p')
[ -z "$ir_max_2" ] && ir_max_2=$ir_max_1
[ -z "$ir_max_3" ] && ir_max_3=$ir_max_2


# --- DETAILED VALIDATION BLOCK ---
# Checks each parsed variable individually and reports the specific failure.
if [ -z "$total_energy" ]; then echo "Error: Failed to parse 'Total Energy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$total_enthalpy" ]; then echo "Error: Failed to parse 'Total Enthalpy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$total_free_energy" ]; then echo "Error: Failed to parse 'Total Free Energy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$zpve" ]; then echo "Error: Failed to parse 'Zero Point Energy (ZPVE)' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$homo_energy" ]; then echo "Error: Failed to parse 'HOMO Energy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$lumo_energy" ]; then echo "Error: Failed to parse 'LUMO Energy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$tot_enthalpy" ]; then echo "Error: Failed to parse 'Total Enthalpy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$tot_heat_capacity" ]; then echo "Error: Failed to parse 'Total Heat Capacity' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$tot_entropy" ]; then echo "Error: Failed to parse 'Total Entropy' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$c6aa" ]; then echo "Error: Failed to parse 'C6AA' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$c8aa" ]; then echo "Error: Failed to parse 'C8AA' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$polarizability" ]; then echo "Error: Failed to parse 'Polarizability' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$dipole" ]; then echo "Error: Failed to parse 'Dipole Moment' for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$vibr_freqs_list" ]; then echo "Error: No valid (positive) vibrational frequencies found for $INPUT_FILE. Skipping." >&2; exit 1; fi
if [ -z "$ir_max_1" ]; then echo "Error: Failed to parse 'IR Intensity 1' for $INPUT_FILE. Skipping." >&2; exit 1; fi
# --- End of Validation ---

# --- Calculate Statistics from Lists ---
# This part is only reached if all validation checks pass.

# Vibrational Frequency Stats
# Using awk for more efficient calculation of mean, variance, and median
stats=$(echo "$vibr_freqs_list" | sort -n | awk '
    {
        count++;
        sum += $1;
        sum_sq += $1 * $1;
        data[count] = $1;
    }
    END {
        mean = sum / count;
        variance = sum_sq / count - mean * mean;
        stddev = sqrt(variance);
        median = (count % 2) ? data[(count + 1) / 2] : (data[count / 2] + data[count / 2 + 1]) / 2;
        print data[1], data[count], mean, median, stddev;
    }
')

min_freq=$(echo "$stats" | awk '{print $1}')
max_freq=$(echo "$stats" | awk '{print $2}')
avg_freq=$(echo "$stats" | awk '{print $3}')
median_freq=$(echo "$stats" | awk '{print $4}')
stddev_freq=$(echo "$stats" | awk '{print $5}')

# --- Write to CSV ---
# Create the header row if the file doesn't exist
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "mol_name,total_energy_Eh,total_enthalpy_Eh,total_free_energy_Eh,homo_Eh,lumo_Eh,dipole_Debye,polarizability_au,c6aa_au,c8aa_au,zpve_Eh,tot_enthalpy_cal_K_mol,heat_capacity_cal_K_mol,entropy_cal_K_mol,min_freq_cm-1,max_freq_cm-1,avg_freq_cm-1,median_freq_cm-1,stddev_freq_cm-1,ir_intensity_max1,ir_intensity_max2,ir_intensity_max3" > "$OUTPUT_FILE"
fi

# Append the data for the current molecule
echo "$mol_name,$total_energy,$total_enthalpy,$total_free_energy,$homo_energy,$lumo_energy,$dipole,$polarizability,$c6aa,$c8aa,$zpve,$tot_enthalpy,$tot_heat_capacity,$tot_entropy,$min_freq,$max_freq,$avg_freq,$median_freq,$stddev_freq,$ir_max_1,$ir_max_2,$ir_max_3" >> "$OUTPUT_FILE"

echo "Successfully saved features for $mol_name to $OUTPUT_FILE"