if [ -d "./cxx/" ];then
    rm -r ./cxx
fi

mkdir ./cxx

sed 's/\#include \"quickjs\/quickjs.h\"/\#include \"quickjs.h\"/g' ../cxx/ffi.h > ./cxx/ffi.h
cp ../cxx/ffi.cpp ./cxx/ffi.cpp

cp -r ../cxx/quickjs/* ./cxx

# Never leave VERSION on Apple case-insensitive FS (clashes with C++ <version>)
rm -f ./cxx/VERSION ./cxx/version ./cxx/VERSION.txt ./cxx/version.txt

rm ./cxx/quickjs.c


quickjs_version=$(cat ../cxx/quickjs/VERSION.txt)

sed '1i\
\#define CONFIG_VERSION \"'$quickjs_version'\"\
\#define DUMP_LEAKS  1\
' ../cxx/quickjs/quickjs.c > ./cxx/quickjs.c