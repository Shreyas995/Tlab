#include "types.h"
#include "dns_const.h"

SUBROUTINE FI_CHEM(chemistry, nx,ny,nz, is, s, source)

  USE DNS_TYPES,  ONLY : term_structure
  USE DNS_GLOBAL, ONLY : ycoor_i
  USE DNS_GLOBAL, ONLY : g

  IMPLICIT NONE

  TYPE(term_structure),         INTENT(IN)  :: chemistry
  TINTEGER,                     INTENT(IN)  :: nx,ny,nz, is
  TREAL, DIMENSION(nx*ny*nz,*), INTENT(IN)  :: s
  TREAL, DIMENSION(nx*ny*nz),   INTENT(OUT) :: source

! -----------------------------------------------------------------------
  TREAL xi, dummy, thickness_inv, ycenter
  TINTEGER i,j,k

!########################################################################
  IF      ( chemistry%type .EQ. EQNS_CHEM_QUADRATIC ) THEN
     source = chemistry%parameters(is) * s(:,2) *s(:,3)

  ELSE IF ( chemistry%type .EQ. EQNS_CHEM_LAYEREDRELAXATION ) THEN

     ycenter = g(2)%nodes(1) + g(2)%scale *ycoor_i(is) + chemistry%parameters(2)
     thickness_inv = C_1_R /chemistry%parameters(3)
     DO i=1,nx
        DO k=1,nz
           DO j=1,ny
              xi = (g(2)%nodes(j)-ycenter) /chemistry%parameters(3)
              source(i+(j-1)*nx+(k-1)*nx*ny) = C_05_R *( C_1_R +TANH(xi) ) !strength constant
           ENDDO
        ENDDO
     ENDDO
     
     dummy  =-C_1_R /chemistry%parameters(1)
     source = dummy *source*s(:,is)
     
  ENDIF  
  
  RETURN
END SUBROUTINE FI_CHEM
