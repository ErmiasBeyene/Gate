#!/bin/bash
########################################################################
# Run Gate locally in parallel by combining the jobsplitter with GNU
# parallel
# Author: M Raedler
########################################################################

SCRIPT_DIR=$(pwd)

# Use date and time as the output directory name
DATE_TIME=$(date +"%Y-%m-%d_%H-%M-%S")

# Depends on how its written in the main.mac
# TODO: Read automatically
GATE_OUTPUT_DIR=Output
GATE_OUTPUT_FILE=results
GATE_OUTPUT_STATS=simulation_statistics

# Allocate the new output dir
OUTPUT_DIR=${SCRIPT_DIR}/${GATE_OUTPUT_DIR}/${DATE_TIME}
mkdir ${OUTPUT_DIR}

# Target output root file size
TARGET_MERGED_ROOT_FILE_SIZE=5000000000  # 5 GB
#~ TARGET_MERGED_ROOT_FILE_SIZE=23000000  # 23 MB

# Create a log file
LOG_FILE=${OUTPUT_DIR}/log.txt
touch ${LOG_FILE}
echo -e "Log file for run_Gate.sh, which locally parallelizes Gate simulations\n\
=====================================================================\n" >> ${LOG_FILE}

########################################################################
# Start with delay
DAYS_DELAY=0
HOURS_DELAY=0
MINUTES_DELAY=0

echo -e "Launched with a delay of ${DAYS_DELAY} days, ${HOURS_DELAY} \
hours and ${MINUTES_DELAY} minutes.\nGoing to sleep for that duration ...\n" | tee -a ${LOG_FILE}

SECONDS_DELAY=$(( ${DAYS_DELAY} * 86400 + ${HOURS_DELAY} * 3600 + ${MINUTES_DELAY} * 60 ))
sleep ${SECONDS_DELAY}
########################################################################

# Some commands, like "ls" or "rm" have a maximum number of input
# arguments, otherwise they print "Argument list too long". To avoid
# this, rum them in batches.
MAX_ARGUMENT=10000

# Technically, the input of run_in_batches is the command to be
# evaluated, however the brace expansion can somehow not be parsed, even
# when using {\$START..\$END}. To make it work, there are two input
# arguments, splitting the command to be executed into before and after
# the brace expansion
run_in_batches() {
	# Estimate the number of cycles: the line below is equivalent to 
	# ceil(NUMBER_OF_SPLITS / MAX_ARGUMENT)
	NUMBER_OF_CYCLES=$(( (${NUMBER_OF_SPLITS} + ${MAX_ARGUMENT} - 1) / ${MAX_ARGUMENT} ))
	
	for (( i = 1; i <= ${NUMBER_OF_CYCLES}; i++ )); do
		# Subdivide into slices 
		START=$(( ($i-1) * ${MAX_ARGUMENT} + 1 ))
		END=$(( $i * ${MAX_ARGUMENT}))
		
		# Cap the top index, for the last pass
		if [ $END -gt ${NUMBER_OF_SPLITS} ]; then
			END=${NUMBER_OF_SPLITS}
		fi
		
		eval $1"{$START..$END}"$2
	done
}

# Track the time
SECONDS=0

# Default values
NUMBER_OF_SPLITS=10
NUMBER_OF_CORES=10

S_NOT_GIVEN=true
c_NOT_GIVEN=true

# Overwrite the default parameters, if given
while getopts ":s:c:" opt; do
	case $opt in
		s)
		S_NOT_GIVEN=false
		NUMBER_OF_SPLITS="$OPTARG"
		;;
		c)
		C_NOT_GIVEN=false
		NUMBER_OF_CORES="$OPTARG"
		;;
		\?) echo "Invalid option -$OPTARG" >&2
		exit 1
		;;
	esac

	case $OPTARG in
		-*) echo "Option $opt needs a valid argument"
		exit 1
		;;
    esac
done

# Warn and report default values, if they are not given
if ${S_NOT_GIVEN} ; then
	echo -e "Warning: Number of splits not given: Using default value of ${NUMBER_OF_SPLITS}" | tee -a ${LOG_FILE}
else
	echo -e "Number of splits: ${NUMBER_OF_SPLITS}" | tee -a ${LOG_FILE}
fi

if ${C_NOT_GIVEN} ; then
	echo -e "Warning: Number of cores not given: Using default value of ${NUMBER_OF_CORES}\n" | tee -a ${LOG_FILE}
else
	echo -e "Number of cores: ${NUMBER_OF_CORES}\n" | tee -a ${LOG_FILE}
fi

# Copy and rename the main.mac file
CP_MAIN=main_${DATE_TIME}_
cp ${SCRIPT_DIR}/main.mac ${SCRIPT_DIR}/${CP_MAIN}.mac

# Replace the output directories in the copied main file
sed -i -e "s|/gate/output/root/setFileName ${GATE_OUTPUT_DIR}/${GATE_OUTPUT_FILE}|/gate/output/root/setFileName ${GATE_OUTPUT_DIR}/${DATE_TIME}/${GATE_OUTPUT_FILE}|g" ${SCRIPT_DIR}/${CP_MAIN}.mac
sed -i -e "s|/gate/actor/simStat/save ${GATE_OUTPUT_DIR}/${GATE_OUTPUT_STATS}.txt|/gate/actor/simStat/save ${GATE_OUTPUT_DIR}/${DATE_TIME}/${GATE_OUTPUT_STATS}.txt|g" ${SCRIPT_DIR}/${CP_MAIN}.mac

# Setting the current directory as the .Gate directory for the jobsplitter
DOT_GATE_DIR=${SCRIPT_DIR}/.Gate
export GC_DOT_GATE_DIR=${SCRIPT_DIR}

# Running jobsplitter: Both clusterplatforms openmosix and xgrid do not need an input 
# script, which is why both options are fine. 
gjs -numberofsplits ${NUMBER_OF_SPLITS} -clusterplatform openmosix ${SCRIPT_DIR}/${CP_MAIN}.mac | tee -a ${LOG_FILE}
echo -e "\n" | tee -a ${LOG_FILE}
# mv ${SCRIPT_DIR}/${CP_MAIN}.submit ${SCRIPT_DIR}/.Gate
rm ${SCRIPT_DIR}/${CP_MAIN}.submit

# gjs -numberofsplits ${NUMBER_OF_SPLITS} -clusterplatform xgrid ${SCRIPT_DIR}/${CP_MAIN}.mac | tee -a ${LOG_FILE}
# echo -e "\n" | tee -a ${LOG_FILE}
# # mv ${SCRIPT_DIR}/${CP_MAIN}.plist ${SCRIPT_DIR}/.Gate
# rm ${SCRIPT_DIR}/${CP_MAIN}.plist

# Remove copied .mac file
rm ${SCRIPT_DIR}/${CP_MAIN}.mac

########################################################################
# Launch in parallel with GNU parallel
echo -e "Launching the Gate simulations. Their huge log is deliberately not printed here.\n\
Relvant statistics are saved in ${GATE_OUTPUT_STATS}.txt.\n" >> ${LOG_FILE}

#ls ${DOT_GATE_DIR}/${CP_MAIN}/*.mac | parallel -j ${NUMBER_OF_CORES} Gate {}
run_in_batches "ls ${DOT_GATE_DIR}/${CP_MAIN}/${CP_MAIN}" ".mac | parallel -j ${NUMBER_OF_CORES} Gate {}"
########################################################################


# Merging the results
echo -e "Finished the Gate simulations. Now merging the results:\n" | tee -a ${LOG_FILE}
echo -e "Target merged root file size: ${TARGET_MERGED_ROOT_FILE_SIZE} bytes." | tee -a ${LOG_FILE}

# Get the mean root output file size (in byte)
TOTAL_ROOT_FILES_SIZE=0
for i in $(seq 1 ${NUMBER_OF_SPLITS}); do 
	ROOT_FILE_SIZE_I=$(stat -c %s ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}$i.root)
	TOTAL_ROOT_FILES_SIZE=$(( ${TOTAL_ROOT_FILES_SIZE} + ${ROOT_FILE_SIZE_I} ))
done 
MEAN_ROOT_FILE_SIZE=$(( ${TOTAL_ROOT_FILES_SIZE} / ${NUMBER_OF_SPLITS} ))
echo -e "Mean root file size: ${MEAN_ROOT_FILE_SIZE} bytes." | tee -a ${LOG_FILE}

# Compute the number of files to merge
N=$(( ${TARGET_MERGED_ROOT_FILE_SIZE} / ${MEAN_ROOT_FILE_SIZE} ))
echo -e "Number of files to merge to yield the target file size: ${N}" | tee -a ${LOG_FILE}

# Find the number closest to N that also divides NUMBER_OF_SPLITS without rest
I=0; SEARCH=1
while [[ $SEARCH -eq 1 ]]; do
    N_M=$((N - I)); N_P=$((N + I))
    if (( NUMBER_OF_SPLITS % N_M == 0 )); then N_D=${N_M}; SEARCH=0; fi
    if (( NUMBER_OF_SPLITS % N_P == 0 )); then N_D=${N_P}; SEARCH=0; fi
    ((I++))
done

# If the nubmer found is no further away from N than N ± N/2, use it
if (( N - N_D < N / 2 && N_D - N < N / 2 )); then 
	MAX_ARGUMENT_NEW=${N_D}
	echo -e "Trying ${N_D} instead, wich divides the number of splits (${NUMBER_OF_SPLITS}) evenly." | tee -a ${LOG_FILE}
else 
	MAX_ARGUMENT_NEW=$N
fi

# The variable MAX_ARGUMENT determines the batch size. Change it to
# adjust the desired file size. If the new batch size is smaller than the default one, set it
if [[ ${MAX_ARGUMENT_NEW} -lt ${MAX_ARGUMENT} ]]; then
    MAX_ARGUMENT=${MAX_ARGUMENT_NEW}
else
    echo -e "${MAX_ARGUMENT_NEW} exceeds ${MAX_ARGUMENT}. Reverting to ${MAX_ARGUMENT}." | tee -a ${LOG_FILE}
fi

EXPECTED_MERGED_ROOT_FILE_SIZE=$(( ${MAX_ARGUMENT} * ${MEAN_ROOT_FILE_SIZE} ))
echo -e "Expected merged file size: ${EXPECTED_MERGED_ROOT_FILE_SIZE} bytes.\n" | tee -a ${LOG_FILE}

########################################################################
# Use the file merger to merge the output files
#gjm ${DOT_GATE_DIR}/${CP_MAIN}/${CP_MAIN}.split -f -outDir ${SCRIPT_DIR}/{GATE_OUTPUT_DIR}/${CP_MAIN} -v 3

# Use hadd instead
run_in_batches "hadd -f ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}_\$i.root ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}" ".root"

# Remove the merged files, if the merging worked
if [ $? -eq 0 ]; then
	#rm ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}?*.root
    run_in_batches "rm ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}" ".root"
else
    echo -e "Error while merging root files." | tee -a ${LOG_FILE}
fi

# # Merge batches
# hadd -f ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}.root ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}_*.root

# # Remove the batches, if the merging worked
# if [ $? -eq 0 ]; then
# 	rm ${OUTPUT_DIR}/${GATE_OUTPUT_FILE}_*?.root
# else
#     echo -e "Error while merging root batches." | tee -a ${LOG_FILE}
# fi
########################################################################


# Also merge the simulation_statistics.txt files into one
echo -e "Merging the ${GATE_OUTPUT_STATS}<...>.txt to ${GATE_OUTPUT_STATS}.txt.\n" | tee -a ${LOG_FILE}
MERGED_SIMULATION_STATISTICS=${OUTPUT_DIR}/${GATE_OUTPUT_STATS}.txt
# rm -f ${MERGED_SIMULATION_STATISTICS}

for i in $(seq 1 ${NUMBER_OF_SPLITS}); do 
	# echo $i
	cat ${OUTPUT_DIR}/${GATE_OUTPUT_STATS}${i}.txt >> "${MERGED_SIMULATION_STATISTICS}"
	echo "" >> "${MERGED_SIMULATION_STATISTICS}"
done

# Remove the individual statistics, if the merging worked
if [ $? -eq 0 ]; then
	#rm ${OUTPUT_DIR}/${GATE_OUTPUT_STATS}?*.txt
    run_in_batches "rm ${OUTPUT_DIR}/${GATE_OUTPUT_STATS}" ".txt"
else
    echo -e "Error while merging the simulation statistics." | tee -a ${LOG_FILE}
fi

# Save the random seeds used in the simulation into a text file
echo -e "Collecting the random seeds in random_seeds.txt.\n" | tee -a ${LOG_FILE}
for i in $(seq 1 ${NUMBER_OF_SPLITS}); do
    RANDOM_SEED=$(grep -oP "/gate/random/setEngineSeed \K.*" ${DOT_GATE_DIR}/${CP_MAIN}/${CP_MAIN}$i.mac)
    echo ${RANDOM_SEED} >> ${OUTPUT_DIR}/random_seeds.txt
done

# Copy an examplatory .mac file (main1.mac) to the output directory 
cp ${DOT_GATE_DIR}/${CP_MAIN}/${CP_MAIN}1.mac ${OUTPUT_DIR}

# Remove the directory of splitted mac scripts
rm -rf ${DOT_GATE_DIR}/${CP_MAIN}

# Estimate days, hours, minutes from SECONDS
DAYS_ECHO=$(( ${SECONDS} / 86400 ))
HOURS_ECHO=$(( ( ${SECONDS} - ( ${DAYS_ECHO} * 86400 )) / 3600 ))
MINUTES_ECHO=$(( ( ${SECONDS} - ( ${DAYS_ECHO} * 86400 ) - ( ${HOURS_ECHO} * 3600 )) / 60 ))
SECONDS_ECHO=$(( ${SECONDS} - ( ${DAYS_ECHO} * 86400 ) - ( ${HOURS_ECHO} * 3600 ) - ( ${MINUTES_ECHO} * 60 ) ))

# Copy the current script to the ouput folder
cp $0 ${OUTPUT_DIR}

echo -e "Done.\nElapsed time:\n${DAYS_ECHO} days, ${HOURS_ECHO} hours, ${MINUTES_ECHO} minutes, and ${SECONDS_ECHO} seconds." | tee -a ${LOG_FILE}
