#!/bin/bash

# >>> START VARS
readonly PROGNAME=$(basename $0)
readonly TEMP=/tmp/$PROGNAME
readonly ARGS="$@"
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
    ${CMDPREFIX}flushcontext -ha ${handler2} >/dev/null 2>&1
    ${CMDPREFIX}flushcontext -ha ${handler1} >/dev/null 2>&1
    /bin/rm -rf $TEMP
    echo -e "OK\n"
}
usage() {
    echo -e "Unseal a file with a PCR policy.\n
SYNTAX:
$0 -if <INFILE> [-pcrf <PCR DATA FILE>] [-ha <HANDLE>] [-of <OUTFILE>] [-h]\n
EXAMPLE:
$0 -if sealedfile\n
OPTIONS:
-if|--infile\tREQUIRED: Input file to unseal (generated with seal.sh)
-pcrf|--pcrfile\tFile with PCR indexes + values. See notes below.
-ha|--handle\tOPTIONAL: Handle for primary storage key. Default = 80000000
-of|--outfile\tOPTIONAL: Output file. Default = <inputfile>.unsealed
-h|--help\tOPTIONAL: Show this help page\n
GENERAL NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified, default 80000000 will be used.\n
NOTES FOR DEFAULT MODE:
- The required PCR indexes will be read from the input file (archive)
- The according will then be read without changing any values
- Make sure the registers store the values you want before running the tool!\n
NOTES FOR PCR FILE MODE (-pcrf):
- Provide the same PCR data file you used to seal the file
- Run \"seal.sh -h\" for additional information
- Make sure the registers are empty when using this mode!\n"
}
pcrmaskgen() {
    let acc=0
    for i in $*; do let acc="$acc+(1<<$i)"; done
    temp=$(echo "ibase=10;obase=16;$acc" | bc)
    temp=$(printf '0%.0s' {1..6})$temp
    echo "${temp:(-6)}"
}
# <<< END HELPERS

# >>> START PROGRAM
trap cleanup EXIT
echo
# initial value
FILEMODE=false
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
        -pcrf|--pcrfile) [[ "$2" == -* ]] && { usage; die "Wrong argument for $1";} || FILEMODE=true; PCRFILE="$2";;
        # check if handle is 8 numbers
        -ha|--handle)   [[ "$2" =~ $REGEX_HA ]] && HA="$2" || { usage; die "Wrong argument for $1";};;
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
[[ $FILEMODE == true && -z $PCRFILE ]] && die "PCR file mode enabled but no file provided."
# for outfile we can generate a default value if nothing was provided
[ -z $OUTPUTFILE ] && { OUTPUTFILE=$(echo $INPUTFILE_BASE | sed 's/\.sealed$//').unsealed; echo "${CONSOLE_INFO}No outfile specified. Using ./${OUTPUTFILE}";}
# for the handle we can use a default value if nothing was provided and we are NOT in setup mode
[ -z $HA ] && { HA=80000000; echo "${CONSOLE_INFO}No handle specified. Using default handle 80000000.";}
# create temp environment
try "/bin/rm -rf $TEMP; mkdir -p $TEMP"
echo -ne "${CONSOLE_INFO}Extracting input archive... "
# extract tar archive
try "base64 -d $INPUTFILE 1>$TEMP/$INPUTFILE_BASE.d64 2>/dev/null"
try "tar -xzf $TEMP/$INPUTFILE_BASE.d64 -C $TEMP >/dev/null 2>&1"
# load mask value
MASK=$(cat $TEMP/*.mask)
echo "OK"
if $FILEMODE; then
    # check if file exists
    [ -f $PCRFILE ] || die "PCR data file does not exists. Please check path."
    echo -ne "${CONSOLE_INFO}Processing PCR data file... "
    # remove empty lines
    sed '/^$/d' $PCRFILE > $TEMP/pcrfcontent
    # empty arrays
    declare -a PCRLIST; declare -a PCRVALUES
    # read two lines at a time and build the arrays
    while read -r l1; do
        # line 1 must be a one or two digit number (checks if empty at the same time)
        [[ $l1 =~ $REGEX_PCRF ]] || die "The index '$l1' in the PCR data file is not numeric only. Please check."
        # and it cant be higher than 23
        [ "$l1" -gt 23 ] && die "The index '$l1' in the PCR data file is too high"
        read -r l2;
        # second line must start with s| or f| and needs at least one character after
        [[ $l2 =~ $REGEX_PCRF_VAL ]] || die "A value in the PCR data file is empty or does not contain the s| or f| prefix. Please check."
        # append the values to the array
        PCRLIST+=("$l1")
        PCRVALUES+=("$l2")
    done < $TEMP/pcrfcontent
    echo "OK"
    # generate a temporary mask value
    try "tmpmask=$(pcrmaskgen ${PCRLIST[@]})"
    # compare if it matches with the one we have in the input archive
    [ "$tmpmask" == "$MASK" ] || die "Mismatch for byte mask between input file archive and PCR data file. Is your file correct?"
    echo -ne "${CONSOLE_INFO}Updating PCR values... "
    # for each index and value pair, create a pcrevent
    for (( i=0; i<${#PCRLIST[@]}; i++ )); do
        [[ ${PCRVALUES[$i]} == s\|* ]] && mode="-ic" || mode="-if"
        tmpvalue=$(echo "${PCRVALUES[$i]}" | sed -e "s/^f|//" | sed -e "s/^s|//")
        try "${CMDPREFIX}pcrevent -ha ${PCRLIST[$i]} $mode '$tmpvalue' >/dev/null 2>&1"
    done
    echo "OK"
fi
echo -ne "${CONSOLE_INFO}Loading extracted keys... "
# load sealed file keys
try "${CMDPREFIX}load -hp ${HA} -ipu $TEMP/*.pub -ipr $TEMP/*.priv > $TEMP/handler1"
# grab the handler
handler1=$(cat $TEMP/handler1 | cut -d " " -f2)
echo "OK"
echo -ne "${CONSOLE_INFO}Preparing auth & policy... "
# set encrypted session = false
export TPM_ENCRYPT_SESSIONS=0
# start auth session
try "${CMDPREFIX}startauthsession -se p > $TEMP/handler2"
# grab the handler
handler2=$(cat $TEMP/handler2 | cut -d " " -f2)
# load the policy
try "${CMDPREFIX}policypcr -ha ${handler2} -bm ${MASK} >/dev/null 2>&1"
echo "OK"
echo -ne "${CONSOLE_INFO}Unsealing file... "
# unseal the file
try "${CMDPREFIX}unseal -ha ${handler1} -se0 ${handler2} 1 -of ${OUTPUTFILE} >/dev/null 2>&1"
echo "OK"
echo -ne "${CONSOLE_INFO}File ${OUTPUTFILE} ... "
[ -s "${OUTPUTFILE}" ] && echo "OK" || echo "FAIL: File empty"
# cleanup
exit 0
# <<< END PROGRAM
