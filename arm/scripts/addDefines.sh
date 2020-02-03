#/bin/bash
# Source this script and you can use the follwoing functions:

# Adds a conditional with STRING to every .c|.cpp|.h file in the current folder recursively
# Usage: addConditional STRING
function addConditional {
    for f in $(find ./ -name '*.c' -or -name '*.cpp' -or -name '*.h') 
    do
        echo -e "#ifdef $1\n" | cat - "$f" > "$f.tmp" && mv "$f.tmp" $f
        echo -e "\n#endif /* $1 */" >> $f;
    done
}