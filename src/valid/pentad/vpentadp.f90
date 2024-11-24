program VPENTADP
    use TLab_Constants, only: wp, wi
    implicit none

    integer(wi), parameter :: nmax = 32, len = 5
    real(wp), dimension(nmax, 5) :: a
    real(wp), dimension(len, nmax) :: x, f
    real(wp), dimension(nmax) :: g, h

    integer(wi) :: n, ij, seed
    real(wp) :: RAN0, error, sol, alpha, beta
    integer(wi) :: im2, im1, ip1, ip2, imm1

! ###################################################################
#define a_a(n) a(n,1)
#define a_b(n) a(n,2)
#define a_c(n) a(n,3)
#define a_d(n) a(n,4)
#define a_e(n) a(n,5)

    seed = 256

! create diagonals for pentadiagonal Toeplitz matrix
    ! a_a(1) = RAN0(seed)
    ! a_b(1) = RAN0(seed)
    ! a_c(1) = RAN0(seed)
    ! a_d(1) = RAN0(seed)
    ! a_e(1) = RAN0(seed)
! example with modified pentadiagonal 6th-order compact scheme
    alpha = 0.56
    beta = 0.090666666666667
    a_a(1) = beta
    a_b(1) = alpha
    a_c(1) = 1.0
    a_d(1) = alpha
    a_e(1) = beta
    do n = 2, nmax
        a_a(n) = a_a(1)
        a_b(n) = a_b(1)
        a_c(n) = a_c(1)
        a_d(n) = a_d(1)
        a_e(n) = a_e(1)
    end do

! create solution
    do n = 1, nmax
        do ij = 1, len
            x(ij, n) = RAN0(seed)
        end do
    end do

! compute forcing term
    imm1 = nmax - 1
    do n = 1, nmax
        im2 = mod(n + nmax - 3, nmax) + 1!n-2; im2=im2+imm1; im2=MOD(im2,nmax)+1
        im1 = mod(n + nmax - 2, nmax) + 1!n-1; im1=im1+imm1; im1=MOD(im1,nmax)+1
        ip1 = mod(n, nmax) + 1!n+1; ip1=ip1+imm1; ip1=MOD(ip1,nmax)+1
        ip2 = mod(n + 1, nmax) + 1!n+2; ip2=ip2+imm1; ip2=MOD(ip2,nmax)+1
        write (*, *) im2, im1, n, ip1, ip2
        do ij = 1, len
            f(ij, n) = x(ij, im2)*a_a(n) + x(ij, im1)*a_b(n) + x(ij, n)*a_c(n) + x(ij, ip1)*a_d(n) + x(ij, ip2)*a_e(n)
        end do
    end do

! ###################################################################

! solve system
    call PENTADPFS(nmax, a_a(1), a_b(1), a_c(1), a_d(1), a_e(1), g(1), h(1))
    call PENTADPSS(nmax, len, a_a(1), a_b(1), a_c(1), a_d(1), a_e(1), g(1), h(1), f)

! error
    error = C_0_R
    sol = C_0_R
    do n = 1, nmax
        do ij = 1, len
            error = error + (f(ij, n) - x(ij, n))*(f(ij, n) - x(ij, n))
            sol = sol + x(ij, n)*x(ij, n)
        end do
    end do
    write (*, *) 'Solution L2-norm ..:', sqrt(sol)
    write (*, *) 'Relative error ....:', sqrt(error)/sqrt(sol)

    stop
end program VPENTADP
