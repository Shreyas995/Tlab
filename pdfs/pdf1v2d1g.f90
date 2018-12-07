#include "types.h"

!########################################################################
!# Tool/Library PDF
!#
!########################################################################
!# HISTORY
!#
!# 2008/04/03 - J.P. Mellado
!#              Created
!#
!########################################################################
!# DESCRIPTION
!#
!# Calculate the PDF over plane of an array u using nbins bins, conditioned
!# on the intermittency field gate.
!# 
!########################################################################
!# ARGUMENTS 
!#
!# igate  In   Level of the gate signal to use as intermittency function
!# ilim   In   If set =0, externally forced through umin_ext/umax_ext
!#             If not, calculate locally the min/max
!#
!########################################################################
SUBROUTINE PDF1V2D1G(ilim, imax,jmax,kmax, j, igate, &
     umin_ext,umax_ext, gate, u, nbins, pdf, wrk1d)

  IMPLICIT NONE

#ifdef USE_MPI
#include "mpif.h"
#endif

  TINTEGER ilim, imax,jmax,kmax, j, nbins
  TREAL umin_ext, umax_ext
  TREAL, INTENT(IN)    :: u(imax,jmax,kmax)
  TREAL, INTENT(OUT)   :: pdf(nbins+2) ! Space at the end for the min and max values in the sample variable
  TREAL, INTENT(INOUT) :: wrk1d(nbins)
  INTEGER(1),INTENT(IN):: gate(imax,jmax,kmax), igate

! -------------------------------------------------------------------
  TINTEGER i, k, ip
  TREAL umin, umax, pdfstep

#ifdef USE_MPI
  INTEGER ims_err, impi
  TREAL umin_p, umax_p
#endif

! ###################################################################
  pdf = C_0_R

! -------------------------------------------------------------------
! Calculate Minimum and Maximum
! -------------------------------------------------------------------
  IF ( ilim .EQ. 0 ) THEN
     umin = umin_ext
     umax = umax_ext

  ELSE
     umin = u(1,j,1)
     umax = u(1,j,1)
     DO k=1, kmax
        DO i=1, imax
           IF ( gate(i,j,k) .EQ. igate ) THEN
              umin = MIN(umin, u(i,j,k))
              umax = MAX(umax, u(i,j,k))
           ENDIF
        ENDDO
     ENDDO

#ifdef USE_MPI
     CALL MPI_ALLREDUCE(umin, umin_p, 1, MPI_REAL8, MPI_MIN, MPI_COMM_WORLD, ims_err)
     umin = umin_p
     CALL MPI_ALLREDUCE(umax, umax_p, 1, MPI_REAL8, MPI_MAX, MPI_COMM_WORLD, ims_err)
     umax = umax_p
#endif

  ENDIF

! Calculate Step in Histogram
  pdfstep = (umax-umin)/M_REAL(nbins)

! Calculate x coordinate of histogram
  pdf(nbins+1) = umin + pdfstep/C_2_R
  pdf(nbins+2) = umax - pdfstep/C_2_R

! -------------------------------------------------------------------
! Calculate Histogram
! -------------------------------------------------------------------
  IF ( ABS(pdfstep) .GT. C_0_R ) THEN
     DO k = 1,kmax
        DO i = 1,imax
           IF ( gate(i,j,k) .EQ. igate ) THEN 
              ip = INT((u(i,j,k)-umin)/pdfstep) + 1
              IF ( ilim .EQ. 0 ) THEN 
                 IF ( ip .LE. nbins .AND. ip .GE. 1 ) THEN
                    pdf(ip) = pdf(ip) + C_1_R
                 ENDIF
              ELSE ! put last point in the last bin
                 ip = MIN(ip,nbins)
                 pdf(ip) = pdf(ip) + C_1_R
              ENDIF
           ENDIF

        ENDDO
     ENDDO

#ifdef USE_MPI
     impi = nbins
     CALL MPI_ALLREDUCE(pdf, wrk1d, impi, MPI_REAL8, MPI_SUM, MPI_COMM_WORLD, ims_err)
     pdf(1:nbins) = wrk1d(1:nbins)
#endif

  ENDIF

  RETURN
END SUBROUTINE PDF1V2D1G

