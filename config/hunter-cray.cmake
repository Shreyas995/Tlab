# HLRS HUNTER - HPE/Cray Compiler (Stuttgart) 

if ( NOT BUILD_TYPE )
   message( WARNING "Setting CMAKE_BUILD_TYPE to default value." )
   set(BUILD_TYPE PARALLEL)
endif()

if ( NOT HYBRID ) 
   set(HYBRID FALSE) 
else()
   message(WARNING "Compiling for hybrid openMP/MPI usage") 
endif() 

if ( NOT PROFILE ) 
   set(PROFILE FALSE) 
endif() 

if ( ${PROFILE} STREQUAL "TRUE" )  
   set(USER_profile_FLAGS "-g")
 endif()
 

# compiler for parallel build and hybrid flags	  
if ( ${BUILD_TYPE} STREQUAL "PARALLEL" )
   set(ENV{FC} ftn) 

   add_definitions(-DUSE_MPI -DUSE_MPI_IO -DUSE_NETCDF -DUSE_ALLTOALL)

   if ( ${HYBRID} STREQUAL "TRUE" )
     set(USER_omp_FLAGS " -fopenmp " )
     add_definitions(-DUSE_OPENMP) 
   endif()

# compiler for serial build
else( ${BUILD_TYPE} STREQUAL "SERIAL" )
  set(ENV{FC} ftn )
  if ( ${HYBRID} STREQUAL "TRUE" )
    set(USER_omp_FLAGS " -fopenmp " )
    add_definitions(-DUSE_OPENMP)
  endif()
endif()     


# set(DRAGONEGG_FLAGS "-finline-aggressive -fslp-vectorize  -fmerge-all-constants") #  -mmadd4 -mfp64 -enable-strided-vectorization")

set(USER_Fortran_FLAGS         "-eZ ${USER_omp_FLAGS}") #-fallow-argument-mismatch from gnu-version10
set(USER_Fortran_FLAGS_RELEASE "-eo -hipa2 -hfp2 -hunroll2 -hfusion2 -hscalar1 " ) #these will be ignored:  -fprefetch-loop-arrays --param prefetch-latency=300") 
set(USER_Fortran_FLAGS_DEBUG   "-O0 -g -debug -ffpe-trap=all") 

if ( NOT CMAKE_BUILD_TYPE ) 
  set(CMAKE_BUILD_TYPE RELEASE)  
endif() 

add_definitions(-DNO_ASSUMED_RANKS -DUSE_FFTW -DHLRS_HAWK -DUSE_NETCDF) # -DUSE_BLAS -DUSE_MKL)
set(FFTW_LIB   "-lfftw3")
set(NCDF_LIB   "-lnetcdff") 
#set(FFTW_INCLUDE_DIR "/opt/hlrs/spack/rev-004_2020-06-17/fftw/3.3.8-clang-9.0.0-2buapgdw/include/")
set(LIBS             "${NCDF_LIB} ${FFTW_LIB} -lm")

set(GNU_SED "gsed")