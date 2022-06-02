#!/bin/bash

# >>> START VARS
readonly PROGNAME=$(basename $0)
readonly TEMP=/tmp/$PROGNAME
readonly ARGS="$@"
readonly ARGNUM="$#"
readonly regex_pcr='^([0-9]{1,2})(,[0-9]{1,2}){0,23}$'
readonly regex_ha='^[0-9]{8}$'
readonly PREFIX=""
# <<< END VARS

# >>> START HELPERS
die() {
    [ -n "$*" ] && echo -e "\n[!] ERROR: $*" 1>&2
    exit 2
}
try() {
    eval $* && return 0
    die "Failed to run '$*'"
}
cleanup() {
    echo -ne "[+] Cleaning up... "
    /bin/rm -rf $TEMP
    echo -e "OK\n"
}
trap cleanup EXIT
usage() {
    echo -e "Seal a file with a PCR policy.\n
SYNTAX:
$0 -if <INFILE> -pcr <PCRS> [-ha <HANDLE>] [-of <OUTFILE>] [-h]\n
EXAMPLE:
$0 -if hello.txt -pcr 16,23\n
OPTIONS:
-if|--infile\tREQUIRED: Input file to seal
-pcr|--pcrlist\tREQUIRED: Comma-separated list of PCR indexes
-ha|--handle\tOPTIONAL: Handle for primary storage key. Default =80000000
-of|--outfile\tOPTIONAL: Output file. Default = <inputfile>.sealed
-h|--help\tOPTIONAL: Show this help page\n
NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified,default 80000000 will be used.
- Values are read from the specified PCRs.\n"
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
        # check if handle is 8 numbers
        -ha|--handle)   [[ "$2" =~ $regex_ha ]] && HA="$2" || { usage; die "Wrong argument for $1";};;
        # check if pcrlist is in correct format
        -pcr|--pcrlist) [[ "$2" =~ $regex_pcr ]] && PCRSTRING="$2" || { usage; die "Wrong argument for $1";};;
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
INPUTFILE_BASE=$(basename $INPUTFILE)
[ -z $PCRSTRING ] && { usage;  die "Missing PCR list. (-pcr)";}
# for outfile we can generate a default value if nothing was provided
[ -z $OUTPUTFILE ] && { OUTPUTFILE=$INPUTFILE_BASE.sealed; echo "[+] No outfile specified. Using ./${OUTPUTFILE}";}
# for the handle we can use a default value if nothing was provided and we are NOT in setup mode
[ -z $HA ] && { HA=80000000; echo "[+] No handle specified. Using default handle 80000000.";}
# convert the pcrlist (comma separated) to an array
oIFS="$IFS"; IFS=","; declare -a PCRARRAY=($PCRSTRING); IFS="$oIFS"; unset oIFS
# check if any number is too high
for pcr in ${PCRARRAY[@]}; do [ "$pcr" -gt 23 ] && die "PCR index ${pcr} too high"; done
# remove duplicates
PCRLIST=($(for pcr in "${PCRARRAY[@]}"; do echo "${pcr}"; done | sort -u))
[ ${#PCRLIST[@]} -lt ${#PCRARRAY[@]} ] && echo "[+] Removed duplicate PCRs. Continuing with ${PCRLIST[*]}."
# create temp environment
try "/bin/rm -rf $TEMP; mkdir -p $TEMP"
# generate bytemask
echo -ne "[+] Generating byte mask... "
try "MASK=$(pcrmaskgen ${PCRLIST[@]})"
echo "${MASK} OK"
echo -ne "[+] Generating policy... "
# create empty file
try "/bin/cp -f /dev/null $TEMP/pcr.txt"
# append the PCR register values to it
cat $TEMP/pcr.txt
for i in ${PCRLIST[@]}; do try "${PREFIX}pcrread -ha $i -ns >> $TEMP/pcr.txt"; done
# generate the policy
try "${PREFIX}policymakerpcr -bm ${MASK} -if $TEMP/pcr.txt -of $TEMP/polpcr.txt >/dev/null 2>&1"
try "${PREFIX}policymaker -if $TEMP/polpcr.txt -of $TEMP/polpcr.bin >/dev/null 2>&1"
echo "OK"
# create the seal
echo -ne "[+] Sealing file... "
try "${PREFIX}create -hp ${HA} -bl -if $INPUTFILE -opu $TEMP/$INPUTFILE_BASE.pub -opr $TEMP/$INPUTFILE_BASE.priv -pol $TEMP/polpcr.bin -ecc nistp256 -uwa >/dev/null 2>&1"
echo "OK"
# write mask to file
echo -ne "[+] Compressing results... "
echo $MASK > $TEMP/$INPUTFILE_BASE.mask
# tar + base64 all 3 files
try "tar -czf $TEMP/tar -C $TEMP $INPUTFILE_BASE.pub $INPUTFILE_BASE.priv $INPUTFILE_BASE.mask >/dev/null 2>&1"
try "base64 $TEMP/tar > $OUTPUTFILE"
echo "OK"
echo -ne "[+] File ${OUTPUTFILE} ... "
[ -s "${OUTPUTFILE}" ] && echo "OK" || echo "FAIL: File empty"
# cleanup
exit 0
# <<< END PROGRAM
