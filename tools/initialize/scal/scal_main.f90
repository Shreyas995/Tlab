#include "types.h"
#include "dns_error.h"
#include "dns_const.h"

#define C_FILE_LOC "INISCAL"

!########################################################################
!# Tool/Library INIT/SCAL
!#
!########################################################################
!# HISTORY
!#
!# 1999/01/01 - C. Pantano
!#              Created
!# 2003/01/01 - J.P. Mellado
!#              Modified
!# 2007/05/09 - J.P. Mellado
!#              Adding multispecies
!# 2007/08/17 - J.P. Mellado
!#              Adding plane perturbation
!#
!########################################################################
PROGRAM INISCAL

  USE DNS_CONSTANTS
  USE DNS_GLOBAL
  USE THERMO_GLOBAL, ONLY : imixture
  USE SCAL_LOCAL
#ifdef USE_MPI
  USE DNS_MPI
#endif

  IMPLICIT NONE

#include "integers.h"
#ifdef USE_MPI
#include "mpif.h"
#endif

! -------------------------------------------------------------------
  TREAL, DIMENSION(:,:), ALLOCATABLE, SAVE, TARGET :: x,y,z
  TREAL, DIMENSION(:,:), ALLOCATABLE, SAVE         :: q,s, txc
  TREAL, DIMENSION(:),   ALLOCATABLE, SAVE         :: wrk1d,wrk2d,wrk3d

  TREAL dummy
  TINTEGER iread_flow, iread_scal, isize_wrk3d, is, ierr, inb_scal_loc

  CHARACTER*64 str, line
  CHARACTER*32 inifile
  
! ###################################################################
  inifile = 'dns.ini'

  CALL DNS_INITIALIZE

  CALL DNS_READ_GLOBAL(inifile)
  CALL SCAL_READ_LOCAL(inifile)
#ifdef CHEMISTRY
  CALL CHEM_READ_GLOBAL(inifile)
#endif

#ifdef USE_MPI
  CALL DNS_MPI_INITIALIZE
#endif

  CALL IO_WRITE_ASCII(lfile,'Initializing scalar fiels.')

  itime = 0; rtime = C_0_R
  
  isize_wrk3d = isize_field
  isize_wrk3d = MAX(isize_wrk1d*300, isize_wrk3d)

! -------------------------------------------------------------------
! Allocating memory space
! -------------------------------------------------------------------      
  ALLOCATE(wrk1d(isize_wrk1d*inb_wrk1d))
  IF ( imode_sim .EQ. DNS_MODE_SPATIAL ) THEN; ALLOCATE(wrk2d(isize_wrk2d*5))
  ELSE;                                        ALLOCATE(wrk2d(isize_wrk2d  ));  ENDIF

  iread_flow = 0
  iread_scal = 1

  IF ( flag_s .EQ. 2 .OR. flag_s .EQ. 3 .OR. radiation%type .NE. EQNS_NONE ) THEN
     inb_txc = 1
  ENDIF

#include "dns_alloc_arrays.h"

! -------------------------------------------------------------------
! Read the grid 
! -------------------------------------------------------------------
#include "dns_read_grid.h"

! ###################################################################
  s = C_0_R

#ifdef USE_MPI
  CALL SCAL_MPIO_AUX ! Needed for options 4, 6, 8
#else
  io_aux(1)%offset = 52 ! header size in bytes
#endif

! ###################################################################
! Non-reacting case
! ###################################################################
#ifdef CHEMISTRY
  IF ( ireactive .EQ. CHEM_NONE ) THEN
#endif

     inb_scal_loc = inb_scal
     IF ( imixture .EQ. MIXT_TYPE_AIRWATER ) THEN
        IF ( damkohler(1) .GT. C_0_R .AND. flag_mixture .EQ. 1 ) THEN
           inb_scal_loc = inb_scal - 1
        ENDIF
     ENDIF
     
! -------------------------------------------------------------------
! Mean
! -------------------------------------------------------------------
     DO is = 1,inb_scal_loc
        CALL SCAL_MEAN(is, s(1,is), wrk1d,wrk2d,wrk3d)
     ENDDO
     
! -------------------------------------------------------------------
! Fluctuation field
! -------------------------------------------------------------------
     DO is = 1,inb_scal_loc
        IF      ( flag_s .EQ. 1 ) THEN
           CALL SCAL_VOLUME_DISCRETE(is, s(1,is))
        ELSE IF ( flag_s .EQ. 2 .AND. norm_ini_s(is) .GT. C_SMALL_R ) THEN
           CALL SCAL_VOLUME_BROADBAND(is, s(1,is), txc, wrk3d)
        ELSE IF ( flag_s .GE. 4 .AND. norm_ini_s(is) .GT. C_SMALL_R ) THEN
           CALL SCAL_PLANE(flag_s, is, s(1,is), wrk2d)
        ENDIF
     ENDDO
     
! Initial liquid, if needed, in equilibrium; we simply overwrite previous values     
     IF ( imixture .EQ. MIXT_TYPE_AIRWATER ) THEN
        IF ( damkohler(1) .GT. C_0_R .AND. flag_mixture .EQ. 1 ) THEN
           CALL THERMO_AIRWATER_PHAL(imax,jmax,kmax, s(1,2), p_init, s(1,1))
        ENDIF
     ENDIF
     
#ifdef CHEMISTRY
! ###################################################################
! Reacting case
! ###################################################################
  ELSE
     is = inb_scal

! pasive scalar field
     IF      ( flag_mixture .EQ. 0 ) THEN
        CALL SCAL_MEAN(is, s(1,is), wrk1d,wrk2d,wrk3d)
     ELSE IF ( flag_mixture .EQ. 2 ) THEN
        CALL DNS_READ_FIELDS('scal.ics', i1, imax,jmax,kmax, i1,i1, isize_wrk3d, s(1,is), wrk3d)
     ENDIF

! species mass fractions
     IF      ( ireactive .EQ. CHEM_FINITE ) THEN
        CALL SCREACT_FINITE(x, s, isize_wrk3d, wrk3d)
     ELSE IF ( ireactive .EQ. CHEM_INFINITE .AND. inb_scal .GT. 1 ) THEN
        CALL SCREACT_INFINITE(x, s, isize_wrk3d, wrk3d)
     ENDIF
     CALL IO_WRITE_ASCII(efile, 'INISCAL. Chemistry part to be checked')
     CALL DNS_STOP(DNS_ERROR_UNDEVELOP)

  ENDIF
#endif

! ------------------------------------------------------------------
! Add Radiation component after the fluctuation field
! ------------------------------------------------------------------
  IF ( radiation%type .NE. EQNS_NONE ) THEN
     
! An initial effect of radiation is imposed as an accumulation during a certain interval of time
     radiation%parameters(1) = norm_ini_radiation
     IF ( imixture .EQ. MIXT_TYPE_AIRWATER_LINEAR ) THEN 
        CALL THERMO_AIRWATER_LINEAR(imax,jmax,kmax, s, s(1,inb_scal_array))
     ENDIF
     DO is = 1,inb_scal
        IF ( radiation%active(is) ) THEN
           CALL OPR_RADIATION(radiation, imax,jmax,kmax, g(2)%jac, s(1,radiation%scalar(is)), txc, wrk1d,wrk3d)
           s(1:isize_field,is) = s(1:isize_field,is) + txc(1:isize_field,1)
        ENDIF
     ENDDO
     
  ENDIF

! ###################################################################
! Output file
! ###################################################################
  CALL DNS_WRITE_FIELDS('scal.ics', i1, imax,jmax,kmax, inb_scal, isize_wrk3d, s, wrk3d)

  CALL DNS_END(0)

  STOP
END PROGRAM INISCAL

! ###################################################################
! ###################################################################
#ifdef USE_MPI

SUBROUTINE SCAL_MPIO_AUX()

  USE DNS_GLOBAL, ONLY : imax_total,jmax_total,kmax_total, imax,jmax,kmax
  USE DNS_MPI
  
  IMPLICIT NONE

#include "mpif.h" 

! -----------------------------------------------------------------------
  TINTEGER                :: ndims, idummy, id
  TINTEGER, DIMENSION(3)  :: sizes, locsize, offset

! #######################################################################
  mpio_aux(:)%active = .FALSE. ! defaults
  mpio_aux(:)%offset = 0

! ###################################################################
! Subarray information to read plane data
! ###################################################################
  id = 1

  mpio_aux(id)%active = .TRUE.
  mpio_aux(id)%communicator = MPI_COMM_WORLD
  mpio_aux(:)%offset  = 52 ! size of header in bytes

  ndims = 3
  sizes(1)  =imax_total;   sizes(2)   = 1; sizes(3)   = kmax_total
  locsize(1)=imax;         locsize(2) = 1; locsize(3) = kmax
  offset(1) =ims_offset_i; offset(2)  = 0; offset(3)  = ims_offset_k
  
  CALL MPI_Type_create_subarray(ndims, sizes, locsize, offset, &
       MPI_ORDER_FORTRAN, MPI_REAL8, mpio_aux(id)%subarray, ims_err)
  CALL MPI_Type_commit(mpio_aux(id)%subarray, ims_err)
  
  RETURN
END SUBROUTINE SCAL_MPIO_AUX

#endif
