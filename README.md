# Generation of XTB Features — How to Use

The final output CSV will contain each molecule’s name and its representation as XTB features.

## Prerequisites

* Install [Miniconda](https://www.anaconda.com/docs/getting-started/miniconda/install#linux-terminal-installer) locally.

---

## 1. Create and Activate the Conda Environment

From the project root:

```bash
conda env create -f xtb_processing.yml
conda activate xtb_processing
# or
conda create --name xtb_processing python=3.12
conda activate xtb_processing
conda install xtb morfeus-ml numpy pandas click xtb-python typing_extensions
```

---

## 2. Configure Input and Output Paths

Edit `process_xtb/generate_xtb_by_batches.py` to set:

* `XYZ_MOLECULES_DIR`: Molecules `.xyz` files path
* `DEFAULT_OUTPUT_DIR` and `COMBINED_XTB_FEATURES_PATH`: Output feature file paths

**Example directory structure:**

```
.
├── bse49/                      # Molecule dataset
│   └── Geometries/
│       ├── Existing/
│       └── Hypothetical/
├── data/                       # Feature output folder
│   └── BSE/                    # Bond separation energies dataset features
│       └── xtb_reps/
├── process_xtb/
│   └── ...
└── src/
    └── ...
```

---

## 3. Test Your Setup

Check dataset size:

```bash
python process_xtb/generate_xtb_by_batches.py size
```

Example output:

```
13182
```

Generate a small test batch:

```bash
python process_xtb/generate_xtb_by_batches.py generate-batch --start_index 0 --batch_size 5
```

Example output:

```
Processing molecules 0 to 4 out of 13182
[0/13182] Running xtb for C-C_1-Butanol_A...
[0/13182] Successfully combined features for: C-C_1-Butanol_A
...
```

Combine outputs:

```bash
python process_xtb/generate_xtb_by_batches.py combine-xtb
```

Example output:

```
Searching for CSV files in: data/BSE/xtb_reps/
Found 5 files to combine.
Successfully combined 5 entries into data/BSE/xtb_features_combined.csv
```

---

## 4. Prepare the HPC Job File

* Update the array size in the job file `process_xtb/process_molecule.sh` (`#SBATCH --array=0-26`) so that:

  ```
  (ARRAY_INDEX_MAX + 1) × BATCH_SIZE ≥ TOTAL_MOLECULES
  ```

  Example: `(26 + 1) × 500 = 13500 > 13182` ✅

* Adjust paths containing your username (replace `trentyth` with yours).

* Update `INPUT_DIR_NAME` and `OUTPUT_DIR_NAME` to match your project and the folder names defined during step 2 in `process_xtb/generate_xtb_by_batches.py`.

* If your molecules are particularly large, reduce the batch size or increase the job runtime to account for the longer processing time required by xTB per molecule.

---

## 5. Build the HPC Apptainer Environment

### a) If you have Docker installed locally

```bash
docker build -f Dockerfile -t deb_xtb_processing .
docker save deb_xtb_processing -o deb_xtb_processing.tar
```

### b) If you do not have Docker or cannot run it

Download the precompiled Docker image [here](https://drive.google.com/file/d/1C-ODlIX3jVcQJ3RYme-cObIyxLCZeFKH/view). And place it next to the `process_xtb/` directory.


### Transfer the image to the HPC

From your local machine:

```bash
scp deb_xtb_processing.tar <username>@<server>:/home/<username>/scratch/deb_xtb_processing.tar
```

### Build the Apptainer `.sif` image on the HPC

On the HPC:

```bash
cd scratch
module load apptainer
apptainer build --fakeroot deb_xtb_processing.sif docker-archive://deb_xtb_processing.tar
```

## 6. Transfer Project Files to HPC

From local machine:

```bash
# Step 1 — copy your data and xtb code directories
rsync -av \
    --exclude='__pycache__/' \
    --exclude='datasets/' \
    --exclude='*.ipynb' \
    --exclude='*.pdf' \
    --exclude='*.csv' \
    --exclude='*.org' \
    --exclude='*.db' \
    bse49 process_xtb hpc_process_xtb/

# Step 2 — create a flat tar for faster extraction on HPC
cd hpc_process_xtb; find . -type f | tar -cf ../hpc_process_xtb_flat.tar -T -; cd ..

# Step 3 — send the tar to HPC
scp hpc_process_xtb_flat.tar <username>@<server>:/home/<username>/scratch/hpc_process_xtb_flat.tar
```

---

## 7. Extract and Run Jobs on the HPC

On the HPC (ssh <username>@<server>):

```bash
cd scratch
mkdir hpc_process_xtb
mv hpc_process_xtb_flat.tar hpc_process_xtb/
cd hpc_process_xtb
tar -xvf hpc_process_xtb_flat.tar
```

### Test with a small batch

Before running the full job, edit the SLURM job file to use a small batch size and reduced resources to verify everything works:

```bash
nano process_xtb/slurm_generation_job.sub
```

Recommended test settings:

```bash
#SBATCH --time=00:30:00 
#SBATCH --array=0-1

...

BATCH_SIZE=5
```

### Monitor the test run

Submit the test job and monitor it:

```bash
sbatch process_xtb/xtb_generation_job.sub
sq
seff <job_id>    # Run after the job starts
```

You can also inspect the `.out` and `.err` files generated in `hpc_process_xtb/` after the job finishes.

---

### Run the full jobs

Once the test completes successfully, restore your full-job settings in `process_xtb/slurm_generation_job.sub`.
Example:

```bash
#SBATCH --time=03:00:00 
#SBATCH --array=0-26

...

BATCH_SIZE=500
```

Then submit the full jobs:

```bash
sbatch process_xtb/xtb_generation_job.sub
```

---

## 8. Combine Output CSVs on HPC

Once all jobs complete:

```bash
module load apptainer
# For me (adapt ./data and ./bse49 to your project and change trentyth to your login)
apptainer exec \
    -B ./process_xtb:/app/process_xtb \
    -B ./data:/app/data \
    -B ./bse49:/app/bse49 \
    /home/trentyth/scratch/deb_xtb_processing.sif \
    bash -c "source /opt/miniconda/etc/profile.d/conda.sh && \
             conda activate xtb_processing && \
             python /home/trentyth/scratch/hpc_process_xtb/process_xtb/generate_xtb_by_batches.py combine-xtb"
```

---

## 9. Download Final CSV to Local Machine

From local:

```bash
# For me (adapt the login, server and path)
scp trentyth@nibi.alliancecan.ca:/home/trentyth/scratch/hpc_process_xtb/data/BSE/xtb_features_combined.csv data/BSE/xtb_features_combined.csv
```