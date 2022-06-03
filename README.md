# tpmsealer
Scripts for sealing / unsealing files using TPM with PCR policies. Can be used for understanding the basics.  

Provided as-is. Was used with a simulated TPM environment. Not sure if it works with an actual device (likely with some adjustments).  
Adjust the PREFIX variable if your environment has different tool names.  

---  
```
# ./seal.sh --help

Seal a file with a PCR policy.

SYNTAX:
../seal.sh -if <INFILE> -pcr <PCRS> -pcrf <PCR DATA FILE> [-ha <HANDLE>] [-of <OUTFILE>] [-h]

EXAMPLE:
../seal.sh -if hello.txt -pcr 16,23

OPTIONS:
-h|--help	OPTIONAL: Show this help page
-if|--infile	REQUIRED: Input file to seal
-pcr|--pcrlist	Comma-separated list of PCR indexes OR
-pcrf|--pcrfile	File with PCR indexes + values. See notes below.
-ha|--handle	OPTIONAL: Handle for primary storage key. Default = 80000000
-of|--outfile	OPTIONAL: Output file. Default = <inputfile>.sealed

GENERAL NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified,default 80000000 will be used.

NOTES FOR PCR LIST MODE:
- The provided indexes will be read on execution without changes values
- Make sure the registers store the values you want before running the tool!

NOTES FOR PCR FILE MODE:
- Only one mode can be used (-pcr or -pcrf)
- Each entry in PCR data file must have two lines: PCR index (1) and value (2)
- Prefix the value with "f|" to interpret it as file or "s|" to interpret it as string
- Files can have absolute paths (recommended) or relative to the working directory on execution
- Entries are processed from top to bottom, duplicate indexes are NOT filtered out
- Make sure the registers are empty when using the PCR data file mode!
- Example file content:
  1
  s|mysecretstring
  2
  f|/home/user/secretfile
```
---  
```
# ./unseal.sh --help

Unseal a file with a PCR policy.

SYNTAX:
../unseal.sh -if <INFILE> [-pcrf <PCR DATA FILE>] [-ha <HANDLE>] [-of <OUTFILE>] [-h]

EXAMPLE:
../unseal.sh -if sealedfile

OPTIONS:
-if|--infile	REQUIRED: Input file to unseal (generated with seal.sh)
-pcrf|--pcrfile	File with PCR indexes + values. See notes below.
-ha|--handle	OPTIONAL: Handle for primary storage key. Default = 80000000
-of|--outfile	OPTIONAL: Output file. Default = <inputfile>.unsealed
-h|--help	OPTIONAL: Show this help page

GENERAL NOTES:
- Must be run in the TPM simulator environment.
- There must already be a parent handler. If none is specified, default 80000000 will be used.

NOTES FOR DEFAULT MODE:
- The required PCR indexes will be read from the input file (archive)
- The according will then be read without changing any values
- Make sure the registers store the values you want before running the tool!

NOTES FOR PCR FILE MODE (-pcrf):
- Provide the same PCR data file you used to seal the file
- Run "seal.sh -h" for additional information
- Make sure the registers are empty when using this mode!
```