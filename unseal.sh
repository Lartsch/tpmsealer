#!/bin/bash

# >>> START VARS
readonly PROGNAME=$(basename $0)
readonly TEMP=/tmp/$PROGNAME
readonly ARGS="$@"
readonly ARGNUM="$#"
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
    ${PREFIX}flushcontext -ha ${handler2} >/dev/null 2>&1
    ${PREFIX}flushcontext -ha ${handler1} >/dev/null 2>&1
    /bin/rm -rf $TEMP
    echo -e "OK\n"
}
trap cleanup EXIT
usage() {
    echo -e "Unseal a file with a PCR policy.\n
SYNTAX:
$0 -if <INFILE> [-ha <HANDLE>] [-of <OUTFILE>] [-h]\n
EXAMPLE:
$0 -if sealedfile\n
OPTIONS:
-if|--infile\tREQUIRED: Input file to unseal (generated with seal.sh)
-ha|--handle\tOPTIONAL: Handle for primary storage key. Default = 80000000
-of|--outfile\tOPTIONAL: Output file. Default = <inputfile>.unsealed
-h|--help\tOPTIONAL: Show this help page\n
NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified, default 80000000 will be used.
- Values are read from the specified PCRs.\n"
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
# for outfile we can generate a default value if nothing was provided
[ -z $OUTPUTFILE ] && { OUTPUTFILE=$(echo $INPUTFILE_BASE | sed 's/\.sealed$//').unsealed; echo "[+] No outfile specified. Using ./${OUTPUTFILE}";}
# for the handle we can use a default value if nothing was provided and we are NOT in setup mode
[ -z $HA ] && { HA=80000000; echo "[+] No handle specified. Using default handle 80000000.";}
# create temp environment
try "/bin/rm -rf $TEMP; mkdir -p $TEMP"
echo -ne "[+] Extracting input archive... "
# extract tar archive
try "base64 -d $INPUTFILE 1>$TEMP/$INPUTFILE_BASE.d64 2>/dev/null"
try "tar -xzf $TEMP/$INPUTFILE_BASE.d64 -C $TEMP >/dev/null 2>&1"
# load mask value
MASK=$(cat $TEMP/*.mask)
echo "OK"
echo -ne "[+] Loading extracted keys... "
# load sealed file keys
try "${PREFIX}load -hp ${HA} -ipu $TEMP/*.pub -ipr $TEMP/*.priv > $TEMP/handler1"
# grab the handler
handler1=$(cat $TEMP/handler1 | cut -d " " -f2)
echo "OK"
echo -ne "[+] Preparing auth & policy... "
# set encrypted session = false
export TPM_ENCRYPT_SESSIONS=0
# start auth session
try "${PREFIX}startauthsession -se p > $TEMP/handler2"
# grab the handler
handler2=$(cat $TEMP/handler2 | cut -d " " -f2)
# load the policy
try "${PREFIX}policypcr -ha ${handler2} -bm ${MASK} >/dev/null 2>&1"
echo "OK"
echo -ne "[+] Unsealing file... "
# unseal the file
try "${PREFIX}unseal -ha ${handler1} -se0 ${handler2} 1 -of ${OUTPUTFILE} >/dev/null 2>&1"
echo "OK"
echo -ne "[+] File ${OUTPUTFILE} ... "
[ -s "${OUTPUTFILE}" ] && echo "OK" || echo "FAIL: File empty"
# cleanup
exit 0
# <<< END PROGRAM
