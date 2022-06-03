#!/bin/bash

# >>> START VARS
readonly PROGNAME=$(basename $0)
readonly TEMP=/tmp/$PROGNAME
readonly ARGS="$@"
readonly REGEX_PCR='^([0-9]{1,2})(,[0-9]{1,2}){0,23}$'
readonly REGEX_HA='^[0-9]{8}$'
readonly REGEX_PCRF='^[0-9]{1,2}$'
readonly REGEX_PCRF_VAL='^(s|f)[|].+$'
readonly CMDPREFIX=""
readonly CONSOLE_INFO="[+] "
readonly CONSOLE_ERR="[!] "
# <<< END VARS

# >>> START HELPERS
die() {
    [ -n "$*" ] && echo -e "\n${CONSOLE_ERR}ERROR: $*" 1>&2
    exit 2
}
try() {
    eval $* && return 0
    die "Failed to run '$*'"
}
# the following function will get "trapped" for the EXIT event (so it is always executed)
cleanup() {
    echo -ne "${CONSOLE_INFO}Cleaning up... "
    /bin/rm -rf $TEMP
    echo -e "OK\n"
}
usage() {
    echo -e "Seal a file with a PCR policy.\n
SYNTAX:
$0 -if <INFILE> -pcr <PCRS> -pcrf <PCR DATA FILE> [-ha <HANDLE>] [-of <OUTFILE>] [-h]\n
EXAMPLE:
$0 -if hello.txt -pcr 16,23\n
OPTIONS:
-if|--infile\tInput file to seal
-pcr|--pcrlist\tComma-separated list of PCR indexes OR
-pcrf|--pcrfile\tFile with PCR indexes + values. See notes below.
-ha|--handle\tOPTIONAL: Handle for primary storage key. Default = 80000000
-of|--outfile\tOPTIONAL: Output file. Default = <inputfile>.sealed
-h|--help\tOPTIONAL: Show this help page\n
GENERAL NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified, default 80000000 will be used.\n
NOTES FOR PCR LIST MODE:
- The provided indexes will be read on execution without changes values
- Make sure the registers store the values you want before running the tool!\n
NOTES FOR PCR FILE MODE:
- Only one mode can be used (-pcr or -pcrf)
- Each entry in PCR data file must have two lines: PCR index (1) and value (2)
- Prefix the value with \"f|\" to interpret it as file or \"s|\" to interpret it as string
- Files can have absolute paths (recommended) or relative to the working directory on execution
- Entries are processed from top to bottom, duplicate indexes are NOT filtered out
- Make sure the registers are empty when using the PCR data file mode!
- Example file content:
  1
  s|mysecretstring
  2
  f|/home/user/secretfile\n" 
}
pcrmaskgen() {
    let acc=0
    for i in $*; do let acc="$acc+(1<<$i)"; done
    temp=$(echo "ibase=10;obase=16;$acc" | bc)
    temp=$(printf '0%.0s' {1..6})$temp
    echo "${temp:(-6)}"
}
trim() {
    local var="$*"
    var="${var#"${var%%[![:space:]]*}"}"
    var="${var%"${var##*[![:space:]]}"}"   
    printf '%s' "$var"
}
# <<< END HELPERS

# >>> START PROGRAM
trap cleanup EXIT
echo
# check if there are any args
[ -z "$ARGS" ] && { usage; die "Missing arguments.";}
# read in the arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        # print usage and exit when help flag is specified
        -h|--help)      usage; exit 0;;
        # no value can start with "-" (would mean the value was skipped)
        -if|--infile)   [[ "$2" == -* ]] && { usage; die "Wrong argument for $1";} || INPUTFILE="$2";;
        -of|--outfile)  [[ "$2" == -* ]] && { usage; die "Wrong argument for $1";} || OUTPUTFILE="$2";;
        -pcrf|--pcrfile) [[ "$2" == -* ]] && { usage; die "Wrong argument for $1";} || PCRFILE="$2";;
        # check if handle is 8 numbers
        -ha|--handle)   [[ "$2" =~ $REGEX_HA ]] && HA="$2" || { usage; die "Wrong argument for $1";};;
        # check if pcrlist is in correct format
        -pcr|--pcrlist) [[ "$2" =~ $REGEX_PCR ]] && PCRSTRING="$2" || { usage; die "Wrong argument for $1";};;
        --)             break;;
        # error handling
        -*)             usage; die "Unknown option $1";;
        *)              ;;
    esac
    # shift so we get the next argument
    shift
done
# additional checks for empty data
[ -z $INPUTFILE ] && { usage;  die "Missing input file. (-if)";}
# check if file exists
[ -f $INPUTFILE ] || die "Input file does not exists. Please check path."
INPUTFILE_BASE=$(basename $INPUTFILE)
[[ -z $PCRSTRING && -z $PCRFILE ]] && { usage;  die "Missing PCR list or file. (-pcr or -pcrf)";}
# only one mode is allowed
[[ -n $PCRSTRING && -n $PCRFILE ]] && { usage;  die "Use only one mode (-pcr or -pcrf)";}
# for outfile we can generate a default value if nothing was provided
[ -z $OUTPUTFILE ] && { OUTPUTFILE=$INPUTFILE_BASE.sealed; echo "${CONSOLE_INFO}No outfile specified. Using ./${OUTPUTFILE}";}
# for the handle we can use a default value if nothing was provided and we are NOT in setup mode
[ -z $HA ] && { HA=80000000; echo "${CONSOLE_INFO}No handle specified. Using default handle 80000000.";}
# create temp environment
try "/bin/rm -rf $TEMP; mkdir -p $TEMP"
# check pcr mode
if ! [ -z $PCRSTRING ]; then
    echo -ne "${CONSOLE_INFO}Processing PCR list... "
    # remove spaces
    PCRSTRING=$(echo "$PCRSTRING" | tr -d " ")
    # convert the pcrlist (comma separated) to an array
    oIFS="$IFS"; IFS=","; declare -a PCRARRAY=($PCRSTRING); IFS="$oIFS"; unset oIFS
    # check if any number is too high
    for pcr in ${PCRARRAY[@]}; do [ "$pcr" -gt 23 ] && die "PCR index ${pcr} too high"; done
    # remove duplicates
    PCRLIST=($(for pcr in "${PCRARRAY[@]}"; do echo "${pcr}"; done | sort -u))
    echo "OK"
    [ ${#PCRLIST[@]} -lt ${#PCRARRAY[@]} ] && echo "${CONSOLE_INFO}Removed duplicate PCRs. Continuing with ${PCRLIST[*]}."
else
    # check if file exists
    [ -f $PCRFILE ] || die "PCR data file does not exists. Please check path."
    echo -ne "${CONSOLE_INFO}Processing PCR data file... "
    # remove empty lines
    sed '/^$/d' $PCRFILE > $TEMP/pcrfcontent
    # empty arrays
    declare -a PCRLIST; declare -a PCRVALUES
    # read two lines at a time and build the arrays
    while read -r l1; do
        # trim leading/trailing spaces without condensing multiple spaces
        l1=$(trim "$l1")
        # line 1 must be a one or two digit number (checks if empty at the same time)
        [[ $l1 =~ $REGEX_PCRF ]] || die "The index '$l1' in the PCR data file is not numeric only. Please check."
        # and it cant be higher than 23
        [ "$l1" -gt 23 ] && die "The index '$l1' in the PCR data file is too high"
        read -r l2;
        l2=$(trim "$l2")
        # second line must start with s| or f| and needs at least one character after
        [[ $l2 =~ $REGEX_PCRF_VAL ]] || die "A value in the PCR data file is empty or does not contain the s| or f| prefix. Please check."
        # append the values to the array
        PCRLIST+=("$l1")
        PCRVALUES+=("$l2")
    done < $TEMP/pcrfcontent
    echo "OK"
    echo -ne "${CONSOLE_INFO}Updating PCR values... "
    # for each index and value pair, create a pcrevent
    for (( i=0; i<${#PCRLIST[@]}; i++ )); do
        [[ ${PCRVALUES[$i]} == s\|* ]] && mode="-ic" || mode="-if"
        tmpvalue=$(echo "${PCRVALUES[$i]}" | sed -e "s/^f|//" | sed -e "s/^s|//")
        try "${CMDPREFIX}pcrevent -ha ${PCRLIST[$i]} $mode '$tmpvalue' >/dev/null 2>&1"
    done
    echo "OK"
fi
# generate bytemask
echo -ne "${CONSOLE_INFO}Generating byte mask... "
try "MASK=$(pcrmaskgen ${PCRLIST[@]})"
echo "${MASK} OK"
echo -ne "${CONSOLE_INFO}Generating policy... "
# create empty file
try "/bin/cp -f /dev/null $TEMP/pcr.txt"
# append the PCR register values to it
for i in ${PCRLIST[@]}; do try "${CMDPREFIX}pcrread -ha $i -ns >> $TEMP/pcr.txt"; done
# generate the policy
try "${CMDPREFIX}policymakerpcr -bm ${MASK} -if $TEMP/pcr.txt -of $TEMP/polpcr.txt >/dev/null 2>&1"
try "${CMDPREFIX}policymaker -if $TEMP/polpcr.txt -of $TEMP/polpcr.bin >/dev/null 2>&1"
echo "OK"
# create the seal
echo -ne "${CONSOLE_INFO}Sealing file... "
try "${CMDPREFIX}create -hp ${HA} -bl -if $INPUTFILE -opu $TEMP/$INPUTFILE_BASE.pub -opr $TEMP/$INPUTFILE_BASE.priv -pol $TEMP/polpcr.bin -ecc nistp256 -uwa >/dev/null 2>&1"
echo "OK"
# write mask to file
echo -ne "${CONSOLE_INFO}Compressing results... "
echo $MASK > $TEMP/$INPUTFILE_BASE.mask
# tar + base64 all 3 files
try "tar -czf $TEMP/tar -C $TEMP $INPUTFILE_BASE.pub $INPUTFILE_BASE.priv $INPUTFILE_BASE.mask >/dev/null 2>&1"
try "base64 $TEMP/tar > $OUTPUTFILE"
echo "OK"
echo -ne "${CONSOLE_INFO}File ${OUTPUTFILE} ... "
[ -s "${OUTPUTFILE}" ] && echo "OK" || echo "FAIL: File empty"
# cleanup
exit 0
# <<< END PROGRAM
