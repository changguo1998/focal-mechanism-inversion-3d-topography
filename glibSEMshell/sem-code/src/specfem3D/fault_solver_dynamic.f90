!=====================================================================
!
!               S p e c f e m 3 D  V e r s i o n  3 . 0
!               ---------------------------------------
!
!     Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                              CNRS, France
!                       and Princeton University, USA
!                 (there are currently many more authors!)
!                           (c) October 2017
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================

! This module implements dynamic faults: spontaneous rupture with prescribed
! friction laws (slip-weakening or rate-and-state) and heterogeneous initial conditions
!
! Authors:
! Percy Galvez, Jean-Paul Ampuero, Tarje Nissen-Meyer, Surendra Somala
!
! Surendra Nadh Somala : heterogenous initial stress capabilities (based on TPV16)
! Surendra Nadh Somala : rate and state friction
! Somala & Ampuero : fault parallelization

module fault_solver_dynamic

  use fault_solver_common

  implicit none

  private

  !slip velocity threshold for healing
  !WARNING: not very robust
  real(kind=CUSTOM_REAL), save :: V_HEALING

  !slip velocity threshold for definition of rupture front
  real(kind=CUSTOM_REAL), save :: V_RUPT

  !Number of time steps defined by the user : NTOUT
  integer, save                :: NTOUT,NSNAP

  ! dynamic rupture simulation
  logical, save :: SIMULATION_TYPE_DYN = .false.

  ! TPV16 for heterogeneous in slip weakening
  logical, save :: TPV16 = .false.

  ! Boundary velocity strengthening layers for TPV10X benchmarks
  logical, save :: TPV10X = .false.

  ! time weakening
  logical, save :: TWF = .false.

  ! rate and state friction (otherwise slip weakening friction)
  logical, save :: RATE_AND_STATE = .false.

  ! RSF_HETE for heterogeneous in rate and state simulation
  logical, save :: RSF_HETE = .false.

  ! rate and state slip law
  integer, parameter :: RSF_SLIP_LAW_TYPE = 1 ! default 1 == SCEC TPV103/104 benchmark slip law, 2 == slip law by Kaneko (2008)

  ! GPU output record length
  integer, parameter :: NT_RECORD_LENGTH = 500

  public :: BC_DYNFLT_init, BC_DYNFLT_set3d_all, &
            SIMULATION_TYPE_DYN, NT_RECORD_LENGTH, &
            fault_transfer_data_GPU, fault_rsf_swf_init_GPU, fault_output_synchronize_GPU, &
            fault_check_mesh_resolution


contains

!=====================================================================
! BC_DYNFLT_init initializes dynamic faults
!
! prname        fault database is read from file prname_fault_db.bin

  subroutine BC_DYNFLT_init(prname)

  use specfem_par, only: nt => NSTEP,DTglobal => DT
  use constants, only: IMAIN,myrank,IIN_PAR,IIN_BIN

  implicit none

  character(len=MAX_STRING_LEN), intent(in) :: prname ! 'proc***'

  ! local parameters
  type(bc_dynandkinflt_type),pointer :: bc
  real(kind=CUSTOM_REAL) :: dt_real
  integer :: iflt,ier,dummy_idfault
  integer :: nbfaults,nbfaults_bin
  integer :: size_Kelvin_Voigt
  integer :: rupture_type
  character(len=MAX_STRING_LEN) :: filename
  ! infos
  integer :: fault_StateLaw,fault_StateLaw_all
  logical :: fault_opening,fault_opening_all
  logical :: fault_healing,fault_healing_all

  NAMELIST / RUPTURE_SWITCHES / RATE_AND_STATE , TPV16 , TPV10X , RSF_HETE, TWF
  NAMELIST / BEGIN_FAULT / dummy_idfault

  ! initializes
  dummy_idfault = 0

  ! note: all processes will open this file
  open(unit=IIN_PAR,file=IN_DATA_FILES(1:len_trim(IN_DATA_FILES))//'Par_file_faults',status='old',iostat=ier)

  ! checks if file exists
  if (ier /= 0) then
    if (myrank == 0) write(IMAIN,*) '  no dynamic faults'
    close(IIN_PAR)
    ! all done, we can return
    return
  endif

  ! number of faults
  read(IIN_PAR,*) nbfaults
  if (nbfaults == 0) then
    !if (myrank == 0) write(IMAIN,*) 'No faults found in file DATA/Par_file_faults'
    ! nothing to do
    return
  endif

  ! checks if binary fault file was created
  filename = prname(1:len_trim(prname))//'fault_db.bin'
  open(unit=IIN_BIN,file=trim(filename),status='old',action='read',form='unformatted',iostat=ier)
  if (ier /= 0) then
    write(IMAIN,*) 'Fatal error: file ',trim(filename),' not found. Abort'
    call exit_MPI(myrank,'Error: fault file fault_db.bin not found')
  endif

  ! Reading etas of each fault
  ! Skip reading viscosity eta of each fault, will be done with binary file
  do iflt = 1,nbfaults
    read(IIN_PAR,*) ! etas
  enddo

  ! fault rupture type: 1 = dyn 2 = kin
  read(IIN_PAR,*) rupture_type

  ! fault simulation type == 1 for dynamic rupture simulation
  ! checks if anything to do
  if (rupture_type /= 1) then
    close(IIN_BIN)
    close(IIN_PAR)
    ! all done
    return
  endif

  ! user output
  if (myrank == 0) then
    write(IMAIN,*) '  incorporating dynamic rupture simulation'
    write(IMAIN,*) '  found ', nbfaults, ' fault(s) in file DATA/Par_file_faults'
  endif

  ! sets dynamic rupture flag
  SIMULATION_TYPE_DYN = .true.

  ! reads parameters:
  !   NTOUT : Number of time steps
  !   NTSNAP: time interaction of snapshots
  !   V_HEALING (-1 : Healing off)
  !   V_RUPT
  read(IIN_PAR,*) NTOUT
  read(IIN_PAR,*) NSNAP
  read(IIN_PAR,*) V_HEALING
  read(IIN_PAR,*) V_RUPT

  ! from binary fault file
  read(IIN_BIN) nbfaults_bin ! should be the same as in IIN_PAR

  ! checks
  if (nbfaults /= nbfaults_bin) then
    print *,'Error: number of faults ',nbfaults,' in Par_file_faults should match number stored in fault_db.bin: ',nbfaults_bin
    print *,'Please check setup and rerun simulation...'
    call exit_MPI(myrank,'Error invalid number of faults in Par_file_faults')
  endif

  ! saves number of faults
  Nfaults = nbfaults
  allocate( faults(nbfaults) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1361')

  dt_real = real(DTglobal)

  ! example line:
  ! &RUPTURE_SWITCHES RATE_AND_STATE=.false.,TPV16=.false./
  read(IIN_PAR,nml=RUPTURE_SWITCHES,end=110,iostat=ier)
  if (ier /= 0) write(*,*) 'RUPTURE_SWITCHES not found in Par_file_faults'

  ! reads in fault parameters
  do iflt = 1,nbfaults
    ! example lines:
    ! &BEGIN_FAULT /
    ! &STRESS_TENSOR Sigma=0e0,0e0,0e0,0e0,0e0,0e0/
    ! ..
    read(IIN_PAR,nml=BEGIN_FAULT,end=100)

    ! initializes fault
    bc => faults(iflt)
    call init_one_fault(bc,IIN_BIN,IIN_PAR,dt_real,nt,iflt,myrank)
  enddo

  ! close files
  close(IIN_BIN)
  close(IIN_PAR)

  ! reads Kelvin-Voigt parameters
  filename = prname(1:len_trim(prname))//'Kelvin_voigt_eta.bin'
  open(unit=IIN_BIN,file=trim(filename),status='old',action='read',form='unformatted',iostat=ier)
  if (ier /= 0) then
    write(IMAIN,*) 'Fatal error: file ',trim(filename),' not found. Abort'
    call exit_MPI(myrank,'Error opening file Kelvin_voigt_eta.bin')
  endif

  ! reads in values
  read(IIN_BIN) size_Kelvin_Voigt
  if (size_Kelvin_Voigt > 0) then
    allocate(Kelvin_Voigt_eta(size_Kelvin_Voigt),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1362')
    read(IIN_BIN) Kelvin_Voigt_eta
  endif
  close(IIN_BIN)
  ! sets flag if this process has damping on fault elements
  if (allocated(Kelvin_Voigt_eta)) then
    USE_KELVIN_VOIGT_DAMPING = .true.
  else
    USE_KELVIN_VOIGT_DAMPING = .false.
  endif

  ! user output
  if (myrank == 0) then
    if (RATE_AND_STATE) then
      write(IMAIN,*) '  using rate and state friction'
    else
      write(IMAIN,*) '  using slip weakening friction'
    endif
    write(IMAIN,*)
    call flush_IMAIN()
  endif

  ! outputs more infos
  do iflt = 1,nbfaults
    ! gets fault info (collected from all processes)
    bc => faults(iflt)
    fault_opening = bc%allow_opening
    fault_StateLaw = 0
    fault_healing = .false.
    if (bc%nspec > 0) then
      if (RATE_AND_STATE) then
        ! checks rate and state evolution law
        if (associated(bc%rsf)) fault_StateLaw = bc%rsf%StateLaw
      else
        ! checks opening
        if (associated(bc%swf)) fault_healing = bc%swf%healing
      endif
    endif
    call max_all_i(fault_StateLaw,fault_StateLaw_all)
    call any_all_l(fault_opening,fault_opening_all)
    call any_all_l(fault_healing,fault_healing_all)

    ! user output
    if (myrank == 0) then
      write(IMAIN,'(a,i2)') '   fault # ',iflt
      if (RATE_AND_STATE) then
        ! rate and state friction
        if (fault_StateLaw_all == 1) then
          write(IMAIN,*) '    State law = ',fault_StateLaw_all,'(ageing law)'
        else
          write(IMAIN,*) '    State law = ',fault_StateLaw_all,'(slip law)'
        endif
      else
        ! slip weakening friction
        if (fault_healing_all) then
          write(IMAIN,*) '    allows for fault healing'
        else
          write(IMAIN,*) '    no fault healing'
        endif
      endif
      ! opening
      if (fault_opening_all) then
        write(IMAIN,*) '    allows for fault opening'
      else
        write(IMAIN,*) '    no fault opening'
      endif
      call flush_IMAIN()
    endif
  enddo

  return

100 if (myrank == 0) write(IMAIN,*) 'Fatal error: did not find BEGIN_FAULT input block in file DATA/Par_file_faults. Abort.'
    call exit_MPI(myrank,'Error: BEGIN_FAULT entry missing')

110 if (myrank == 0) write(IMAIN,*) 'Fatal error: did not find RUPTURE_SWITCHES input block in file DATA/Par_file_faults. Abort.'
    call exit_MPI(myrank,'Error: RUPTURE_SWITCHES entry missing')

  end subroutine BC_DYNFLT_init

!---------------------------------------------------------------------

  subroutine fault_transfer_data_GPU()

  use specfem_par, only: Fault_pointer

  implicit none

  ! local parameters
  type(bc_dynandkinflt_type),pointer :: bc
  integer :: ifault,nspec,nglob

  ! initialize fault solver on GPU
  call initialize_fault_solver_gpu(Fault_pointer, Nfaults, V_HEALING, V_RUPT, RATE_AND_STATE)

  ! initializes each fault
  do ifault = 1,Nfaults
    bc => faults(ifault)
    ! using a record length nt (500), which will be used also for outputting records
    call initialize_fault_data_gpu(Fault_pointer, ifault-1, bc%dataT%iglob, bc%dataT%npoin, bc%dataT%ndat, NT_RECORD_LENGTH)
  enddo

  ! copies fault data fields to GPU
  do ifault = 1,Nfaults
    bc => faults(ifault)

    ! checks features
    if (TWF) stop 'Fault time-weakening not implemented yet on GPU'
    if (TPV16) stop 'Fault TPV16 friction coefficients not implemented yet on GPU'

    nspec = bc%nspec
    nglob = bc%nglob

    ! copies arrays onto GPU
    call transfer_fault_data_to_device(Fault_pointer, ifault-1, &
                                       nspec, nglob, &
                                       bc%D, &
                                       bc%T0, bc%T, &
                                       bc%B, bc%R, bc%V, &
                                       bc%Z, &
                                       bc%invM1, bc%invM2, &
                                       bc%ibulk1, bc%ibulk2, &
                                       bc%allow_opening)
  enddo

  end subroutine fault_transfer_data_GPU

!---------------------------------------------------------------------

  subroutine init_one_fault(bc,IIN_BIN,IIN_PAR,dt_real,NT,iflt,myrank)

  use constants, only: PARALLEL_FAULT

  implicit none
  type(bc_dynandkinflt_type), intent(inout) :: bc
  integer, intent(in)                 :: IIN_BIN,IIN_PAR
  integer, intent(in)                 :: NT,iflt
  real(kind=CUSTOM_REAL), intent(in)  :: dt_real
  integer, intent(in) :: myrank

  real(kind=CUSTOM_REAL) :: S1,S2,S3,Sigma(6)
  integer :: n1,n2,n3,ier,recordlength
  logical :: LOAD_STRESSDROP = .false.

  NAMELIST / INIT_STRESS / S1,S2,S3,n1,n2,n3
  NAMELIST /STRESS_TENSOR / Sigma

  ! reads in fault_db binary file and initializes fault arrays
  call initialize_fault(bc,IIN_BIN)

  ! sets up initial fault state
  if (bc%nspec > 0) then
    allocate(bc%T(3,bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1363')
    allocate(bc%D(3,bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1364')
    allocate(bc%V(3,bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1365')
    bc%T(:,:) = 0.0_CUSTOM_REAL
    bc%D(:,:) = 0.0_CUSTOM_REAL
    bc%V(:,:) = 0.0_CUSTOM_REAL

    ! Set initial fault stresses
    allocate(bc%T0(3,bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1366')
    bc%T0(:,:) = 0.0_CUSTOM_REAL

    S1 = 0.0_CUSTOM_REAL
    S2 = 0.0_CUSTOM_REAL
    S3 = 0.0_CUSTOM_REAL
    n1 = 0
    n2 = 0
    n3 = 0
    read(IIN_PAR, nml=STRESS_TENSOR)
    read(IIN_PAR, nml=INIT_STRESS)

    ! initial fault stress
    bc%T0(1,:) = S1
    bc%T0(2,:) = S2
    bc%T0(3,:) = S3

    if (LOAD_STRESSDROP) then
      call make_frictional_stress()
      call load_stress_drop()
    endif

    call init_2d_distribution(bc%T0(1,:),bc%coord,IIN_PAR,n1)
    call init_2d_distribution(bc%T0(2,:),bc%coord,IIN_PAR,n2)
    call init_2d_distribution(bc%T0(3,:),bc%coord,IIN_PAR,n3)

    ! adds the fault traction caused by a regional stress field
    call init_fault_traction(bc,Sigma)

    ! sets initial stress
    bc%T(:,:) = bc%T0(:,:)

    !WARNING : Quick and dirty free surface condition at z=0
    !  do k = 1,bc%nglob
    !    if (abs(bc%zcoord(k)-0.e0_CUSTOM_REAL) <= SMALLVAL) bc%T0(2,k) = 0
    !  enddo

    ! Set friction parameters and initialize friction variables
    allocate(bc%mu(bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1367')
    bc%mu(:) = 0.0_CUSTOM_REAL

    if (RATE_AND_STATE) then
      ! rate and state friction
      allocate(bc%rsf,stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1368')

      call rsf_init(bc%rsf,bc%T0,bc%V,bc%Fload,bc%coord,IIN_PAR)

    else
      ! slip weakening friction
      allocate(bc%swf,stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1369')

      call swf_init(bc%swf,bc%mu,bc%coord,IIN_PAR)

      ! TPV16 benchmark
      if (TPV16) call TPV16_init() !WARNING: ad hoc, initializes T0 and swf

      ! time weakening friction
      if (TWF) then
        allocate(bc%twf,stat=ier)
        if (ier /= 0) call exit_MPI_without_rank('error allocating twf array')

        call twf_init(bc%twf,IIN_PAR)
      endif
    endif

!! unused
! added by kangchen, this is specifically made for the Balochistan simulation
!  call load_stress_tpv35()

  else
    ! dummy allocations (for subroutine arguments)
    allocate(bc%T(3,1), &
             bc%D(3,1), &
             bc%V(3,1))
  endif

  ! output dataT structure
  if (RATE_AND_STATE) then
    ! rate and state friction
    recordlength = 8  ! number of quantities to store for each record

    call init_dataT(bc%dataT,bc%coord,bc%nglob,NT,dt_real,recordlength,iflt)

    ! adds state output
    if (bc%dataT%npoin > 0) then
      bc%dataT%longFieldNames(8) = "log10 of state variable (log-seconds)"
      if (bc%rsf%StateLaw == 1) then
        ! ageing law
        bc%dataT%shortFieldNames = trim(bc%dataT%shortFieldNames)//" log-theta"
      else
        ! slip law
        bc%dataT%shortFieldNames = trim(bc%dataT%shortFieldNames)//" psi"
      endif
    endif
  else
    ! slip weakening friction
    recordlength = 7  ! number of quantities to store for each record

    call init_dataT(bc%dataT,bc%coord,bc%nglob,NT,dt_real,recordlength,iflt)
  endif

  call init_dataXZ(bc%dataXZ,bc)

  ! output a fault snapshot at t=0
  if (PARALLEL_FAULT) then
    call gather_dataXZ(bc)
    if (myrank == 0) call write_dataXZ(bc%dataXZ_all,0,iflt)
  else
    ! fault in single slice
    if (bc%nspec > 0) call write_dataXZ(bc%dataXZ,0,iflt)
  endif

  contains

    !-----

    subroutine TPV16_init()

    use constants, only: IIN_FLT

    implicit none

    integer :: i,ier, ipar
    real(kind=CUSTOM_REAL), dimension(bc%nglob) :: loc_str,loc_dip,sigma0,tau0_str,tau0_dip,Rstress_str,Rstress_dip,static_fc, &
         dyn_fc,swcd,cohes,tim_forcedRup
    integer, dimension(bc%nglob) :: inp_nx,inp_nz
    real(kind=CUSTOM_REAL) :: minX, siz_str,siz_dip, hypo_loc_str,hypo_loc_dip,rad_T_str,rad_T_dip
    integer :: relz_num,sub_relz_num, num_cell_str,num_cell_dip, hypo_cell_str,hypo_cell_dip
    integer, parameter :: IIN_NUC = IIN_FLT

    open(unit=IIN_NUC,file=IN_DATA_FILES(1:len_trim(IN_DATA_FILES))//'input_file.txt',status='old',iostat=ier)
    if (ier /= 0) then
      print *,'Error opening file ',IN_DATA_FILES(1:len_trim(IN_DATA_FILES))//'input_file.txt'
      print *,'Please check setup for TPV16 example...'
      stop 'Error opening file input_file.txt for TPV16'
    endif

    read(IIN_NUC,*) relz_num,sub_relz_num
    read(IIN_NUC,*) num_cell_str,num_cell_dip,siz_str,siz_dip
    read(IIN_NUC,*) hypo_cell_str,hypo_cell_dip,hypo_loc_str,hypo_loc_dip,rad_T_str,rad_T_dip
    do ipar = 1,bc%nglob
      read(IIN_NUC,*) inp_nx(ipar),inp_nz(ipar),loc_str(ipar),loc_dip(ipar),sigma0(ipar),tau0_str(ipar),tau0_dip(ipar), &
           Rstress_str(ipar),Rstress_dip(ipar),static_fc(ipar),dyn_fc(ipar),swcd(ipar),cohes(ipar),tim_forcedRup(ipar)
    enddo
    close(IIN_NUC)

    minX = minval(bc%coord(1,:))

    do i = 1,bc%nglob
      ! WARNING: nearest neighbor interpolation
      ! loc_dip is negative of Z-coord
      ipar = minloc( (minX+loc_str(:)-bc%coord(1,i))**2 + (-loc_dip(:)-bc%coord(3,i))**2 , 1)

      ! initial stress
      bc%T0(3,i) = -sigma0(ipar)
      bc%T0(1,i) = tau0_str(ipar)
      bc%T0(2,i) = tau0_dip(ipar)

      bc%swf%mus(i) = static_fc(ipar)   ! static friction coefficient
      bc%swf%mud(i) = dyn_fc(ipar)      ! dynamic friction coefficient
      bc%swf%Dc(i) = swcd(ipar)         ! critical slip distance
      bc%swf%C(i) = cohes(ipar)         ! cohesion
      bc%swf%T(i) = tim_forcedRup(ipar) ! (forced) rupture time

    enddo

    end subroutine TPV16_init

    !-------

    subroutine make_frictional_stress()

    implicit none

    real(kind=CUSTOM_REAL),dimension(bc%nglob) :: T1tmp, T2tmp

    !T1tmp=sign(abs(bc%T0(3,:)*0.3*abs(bc%T0(1,:))/sqrt(bc%T0(1,:)*bc%T0(1,:)+bc%T0(2,:)*bc%T0(2,:))),bc%T0(1,:))
    !T2tmp=sign(abs(bc%T0(3,:)*0.3*abs(bc%T0(2,:))/sqrt(bc%T0(1,:)*bc%T0(1,:)+bc%T0(2,:)*bc%T0(2,:))),bc%T0(2,:))

    T1tmp = 0.0_CUSTOM_REAL
    T2tmp = -bc%T0(3,:) * 0.3
    bc%T0(1,:) = T1tmp
    bc%T0(2,:) = T2tmp

    end subroutine make_frictional_stress

    !--------

    subroutine load_stress_drop()   !added by kangchen this is specially made for Balochistan Simulation

    use constants, only: IIN_FLT
    use specfem_par, only: prname

    implicit none

    real(kind=CUSTOM_REAL),dimension(bc%nglob) :: T1tmp, T2tmp
    character(len=70) :: filename
    integer :: ier

    filename = prname(1:len_trim(prname))//'fault_prestr.bin'

    ! debug output
    !print *,'debug: loading stress drop:', trim(filename),bc%nglob

    open(unit=IIN_FLT,file=trim(filename),status='old',action='read',form='unformatted',iostat=ier)
    if (ier /= 0) then
      print *,'Error opening file ',trim(filename)
      print *,'Please check setup for loading stress drop...'
      stop 'Error opening file fault_prestr.bin'
    endif

    read(IIN_FLT) T1tmp
    read(IIN_FLT) T2tmp
    close(IIN_FLT)

    !debug
    ! print *,'debug: loading stress drop:',trim(filename),bc%nglob,'successful'

    bc%T0(1,:) = bc%T0(1,:) - T1tmp
    bc%T0(2,:) = bc%T0(2,:) - T2tmp

    end subroutine load_stress_drop

!! unused
!   subroutine load_stress_tpv35
!
!   use specfem_par, only: prname
!
!   implicit none
!
!   real(kind=CUSTOM_REAL),dimension(bc%nglob) :: stresstmp, mustmp
!   character(len=70) :: filename
!   integer :: ier
!
!   filename = prname(1:len_trim(prname))//'tpv35_input.bin'
!   write(*,*) prname,bc%nglob
!   open(unit=IIN_FLT,file=trim(filename),status='old',action='read',form='unformatted',iostat=ier)
!   read(IIN_FLT) stresstmp
!   read(IIN_FLT) mustmp
!   close(IIN_FLT)
!   !   write(*,*) prname,bc%nglob,'successful'
!
!   bc%T0(1,:)=stresstmp
!   bc%T(1,:) = stresstmp
!   bc%swf%mus = mustmp
!
!   end subroutine load_stress_tpv35


  end subroutine init_one_fault

!---------------------------------------------------------------------
! REPLACES the value of a fault parameter inside an area with prescribed shape

  subroutine init_2d_distribution(array,coord,iin,n)

!JPA refactor: background value should be an argument

  use constants, only: PI
  implicit none

  real(kind=CUSTOM_REAL), intent(inout) :: array(:)
  real(kind=CUSTOM_REAL), intent(in) :: coord(:,:)
  integer, intent(in) :: iin,n

  real(kind=CUSTOM_REAL) :: b(size(array))
  character(len=MAX_STRING_LEN) :: shapeval
  real(kind=CUSTOM_REAL) :: val,valh, xc, yc, zc, r, rc, l, lx,ly,lz
  real(kind=CUSTOM_REAL) :: r1(size(array))
  real(kind=CUSTOM_REAL) :: tmp1(size(array)),tmp2(size(array)),tmp3(size(array))

  integer :: i
  real(kind=CUSTOM_REAL) :: SMALLVAL

  NAMELIST / DIST2D / shapeval, val,valh, xc, yc, zc, r, rc, l, lx,ly,lz

  SMALLVAL = 1.e-10_CUSTOM_REAL

  if (n == 0) return

  do i = 1,n
    shapeval = ''
    val  = 0.0_CUSTOM_REAL
    valh = 0.0_CUSTOM_REAL
    xc = 0.0_CUSTOM_REAL
    yc = 0.0_CUSTOM_REAL
    zc = 0.0_CUSTOM_REAL
    r = 0.0_CUSTOM_REAL
    l = 0.0_CUSTOM_REAL
    lx = 0.0_CUSTOM_REAL
    ly = 0.0_CUSTOM_REAL
    lz = 0.0_CUSTOM_REAL
    rc = 0.0_CUSTOM_REAL

    ! reads in nucleation distribution (shape, position,..)
    read(iin,DIST2D)

    select case (shapeval)
    case ('circle')
      tmp1(:) = r - sqrt((coord(1,:)-xc)**2 + (coord(2,:)-yc)**2 + (coord(3,:)-zc)**2)
      b(:) = heaviside( tmp1(:) ) * val

    case ('circle-exp')
      r1(:) = sqrt((coord(1,:)-xc)**2 + (coord(2,:)-yc)**2 + (coord(3,:)-zc)**2)
      where(r1(:) < r)
        b(:) = exp(r1(:)**2/(r1(:)**2 - r**2) ) * val + valh
      elsewhere
        b(:) = 0.0_CUSTOM_REAL
      endwhere

    case ('ellipse')
      tmp1(:) = 1.0_CUSTOM_REAL - sqrt( (coord(1,:)-xc)**2/lx**2 + (coord(2,:)-yc)**2/ly**2 + (coord(3,:)-zc)**2/lz**2)
      b(:) = heaviside( tmp1(:) ) * val

    case ('square')
      tmp1(:) = (l/2.0_CUSTOM_REAL)-abs(coord(1,:)-xc)+SMALLVAL
      tmp2(:) = (l/2.0_CUSTOM_REAL)-abs(coord(2,:)-yc)+SMALLVAL
      tmp3(:) = (l/2.0_CUSTOM_REAL)-abs(coord(3,:)-zc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * heaviside( tmp3(:) ) * val

    case ('x-cylinder')
      tmp1(:) = r - sqrt((coord(2,:)-yc)**2 + (coord(3,:)-zc)**2)
      tmp2(:) = (lz/2.0_CUSTOM_REAL)-abs(coord(1,:)-xc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * val

    case ('y-cylinder')
      tmp1(:) = r - sqrt((coord(3,:)-zc)**2 + (coord(1,:)-xc)**2)
      tmp2(:) = (lz/2.0_CUSTOM_REAL)-abs(coord(2,:)-yc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * val

    case ('z-cylinder')
      tmp1(:) = r - sqrt((coord(1,:)-xc)**2 + (coord(2,:)-yc)**2)
      tmp2(:) = (lz/2.0_CUSTOM_REAL)-abs(coord(3,:)-zc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * val

    case ('cylindertaper')
      r1(:) = sqrt(((coord(1,:)-xc)**2 + (coord(3,:)-zc)**2 ));
      where(r1(:) < rc)
        where(r1(:) < r)
          b(:) = val;
        elsewhere
          b(:) = 0.5_CUSTOM_REAL*val*(1.0_CUSTOM_REAL+cos(PI*(r1(:)-r)/(rc-r)))
        endwhere
      elsewhere
        b(:) = 0.0_CUSTOM_REAL
      endwhere

    case ('rectangle')
      tmp1(:) = (lx/2.0_CUSTOM_REAL)-abs(coord(1,:)-xc)+SMALLVAL
      tmp2(:) = (ly/2.0_CUSTOM_REAL)-abs(coord(2,:)-yc)+SMALLVAL
      tmp3(:) = (lz/2.0_CUSTOM_REAL)-abs(coord(3,:)-zc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * heaviside( tmp3(:) ) * val

    case ('rectangle-taper')
      tmp1(:) = (lx/2.0_CUSTOM_REAL)-abs(coord(1,:)-xc)+SMALLVAL
      tmp2(:) = (ly/2.0_CUSTOM_REAL)-abs(coord(2,:)-yc)+SMALLVAL
      tmp3(:) = (lz/2.0_CUSTOM_REAL)-abs(coord(3,:)-zc)+SMALLVAL
      b(:) = heaviside( tmp1(:) ) * heaviside( tmp2(:) ) * heaviside( tmp3(:) ) &
          * (val + ( coord(3,:) - zc + lz/2.0_CUSTOM_REAL ) * (valh-val)/lz )

    case default
      stop 'bc_dynflt_3d::init_2d_distribution:: unknown shape'
    end select

   ! REPLACE the value inside the prescribed area
    where (b(:) /= 0.0_CUSTOM_REAL) array(:) = b(:)
  enddo

  end subroutine init_2d_distribution

!---------------------------------------------------------------------


  subroutine init_fault_traction(bc,Sigma)

! computes the traction on the fault plane according to a uniform regional stress field

  implicit none
  type(bc_dynandkinflt_type), intent(inout) :: bc
  real(kind=CUSTOM_REAL),dimension(6), intent(in) :: Sigma
  real(kind=CUSTOM_REAL),dimension(3,bc%nglob) :: Traction

  !sigma_xx => sigma(1)
  !sigma_yy => sigma(2)
  !sigma_zz => sigma(3)
  !sigma_xy => sigma(4)
  !sigma_yz => sigma(5)
  !sigma_xz => sigma(6) negative means compression

  Traction(1,:) = Sigma(1)*bc%R(3,1,:) + Sigma(4)*bc%R(3,2,:) + Sigma(6)*bc%R(3,3,:)
  Traction(2,:) = Sigma(4)*bc%R(3,1,:) + Sigma(2)*bc%R(3,2,:) + Sigma(5)*bc%R(3,3,:)
  Traction(3,:) = Sigma(6)*bc%R(3,1,:) + Sigma(5)*bc%R(3,2,:) + Sigma(3)*bc%R(3,3,:)

  ! rotates forward to fault plane orientation
  Traction(:,:) = rotate(bc,Traction,1)

  ! updates initial fault stress
  bc%T0(:,:) = bc%T0(:,:) + Traction(:,:)

  end subroutine init_fault_traction


!---------------------------------------------------------------------

  elemental function heaviside(x)

  implicit none

  real(kind=CUSTOM_REAL), intent(in) :: x
  real(kind=CUSTOM_REAL) :: heaviside

  if (x >= 0e0_CUSTOM_REAL) then
    heaviside = 1e0_CUSTOM_REAL
  else
    heaviside = 0e0_CUSTOM_REAL
  endif

  end function heaviside

!=====================================================================
! adds boundary term Bt into Force array for each fault.
!
! NOTE: On non-split nodes at fault edges, dD=dV=dA=0
! and the net contribution of B*T is =0
!
  subroutine bc_dynflt_set3d_all(F,V,D)

  implicit none

! arrays:
!   F == accel - (output) force/acceleration
!   V == veloc - (input) velocity
!   D == displ - (input) displacement

  real(kind=CUSTOM_REAL), dimension(:,:), intent(in) :: V,D
  real(kind=CUSTOM_REAL), dimension(:,:), intent(inout) :: F

  ! local parameters
  integer :: iflt

  ! checks if anything to do
  if (Nfaults == 0) return

  ! loops over faults
  do iflt = 1,Nfaults
    ! note: this routine should be called by all processes, regardless if they contain no fault elements,
    !       for managing MPI calls and file outputs
    call BC_DYNFLT_set3d(faults(iflt),F,V,D,iflt)
  enddo

  end subroutine bc_dynflt_set3d_all

!---------------------------------------------------------------------

  subroutine BC_DYNFLT_set3d(bc,MxA,V,D,iflt)

  use constants, only: PARALLEL_FAULT
  use specfem_par, only: it,NSTEP,myrank

  implicit none

  ! fault
  type(bc_dynandkinflt_type), intent(inout) :: bc
  ! force/accel
  real(kind=CUSTOM_REAL), intent(inout) :: MxA(:,:)
  ! velocity,displacement
  real(kind=CUSTOM_REAL), intent(in) :: V(:,:),D(:,:)
  ! fault id
  integer, intent(in) :: iflt

  ! local parameters
  real(kind=CUSTOM_REAL), dimension(3,bc%nglob) :: T,dD,dV,dA
  real(kind=CUSTOM_REAL), dimension(bc%nglob) :: Tstick,Tnew
  real(kind=CUSTOM_REAL), dimension(bc%nglob) :: strength, theta_old, theta_new, dc
  real(kind=CUSTOM_REAL), dimension(bc%nglob) :: Vf_old, Vf_new, TxExt, tmp_Vf
  real(kind=CUSTOM_REAL) :: half_dt,TLoad,DTau0,GLoad,timeval
  integer :: i,ipoin,iglob
  real(kind=CUSTOM_REAL) :: nuc_x, nuc_y, nuc_z, nuc_r, nuc_t0, nuc_v, dist, tw_r, coh_size

! note: this implementation follows the description in:
!       - rate and state friction:
!          Kaneko, Y., N. Lapusta, J.-P. Ampuero (2008)
!          Spectral element modeling of spontaneous earthquake rupture on rate and state faults: Effect of
!          velocity-strengthening friction at shallow depths,
!          JGR, 113, B09317, doi:10.1029/2007JB005553
!
!       - slip weakening friction:
!          Galvez, P., J.-P. Ampuero, L.A. Dalguer, S.N. Somala, T. Nissen-Meyer (2014)
!          Dynamic earthquake rupture modelled with an unstructured 3-D spectral element method applied to
!          the 2011 M9 Tohoku earthquake,
!          Geophys. J. Int., 198, 1222-1240.
!
!       More features have been added, including:
!          fault opening, fault healing, time-weakening, smooth loading,
!          and TPV16 benchmark specific friction handling

  ! for parallel faults
  if (bc%nspec > 0) then

    half_dt = 0.5_CUSTOM_REAL * bc%dt
    Vf_old(:) = sqrt(bc%V(1,:)*bc%V(1,:) + bc%V(2,:)*bc%V(2,:))

    ! get predicted values
    dD(:,:) = get_jump(bc,D) ! dD_predictor
    dV(:,:) = get_jump(bc,V) ! dV_predictor
    dA(:,:) = get_weighted_jump(bc,MxA) ! dA_free

    ! rotate to fault frame (tangent,normal)
    ! component 3 is normal to the fault
    dD(:,:) = rotate(bc,dD,1)
    dV(:,:) = rotate(bc,dV,1)
    dA(:,:) = rotate(bc,dA,1)

    ! T_stick "stick traction"
    T(1,:) = bc%Z(:) * ( dV(1,:) + half_dt*dA(1,:) )
    T(2,:) = bc%Z(:) * ( dV(2,:) + half_dt*dA(2,:) )
    T(3,:) = bc%Z(:) * ( dV(3,:) + half_dt*dA(3,:) )

    !Warning : dirty particular free surface condition z = 0.
    !  where (bc%zcoord(:) > - SMALLVAL) T(2,:) = 0
    ! do k = 1,bc%nglob
    !   if (abs(bc%zcoord(k)-0.e0_CUSTOM_REAL) < SMALLVAL) T(2,k) = 0.e0_CUSTOM_REAL
    ! enddo

    ! add initial stress
    T(:,:) = T(:,:) + bc%T0(:,:)

    ! Solve for normal stress (negative is compressive)
    ! Opening implies free stress
    if (bc%allow_opening) T(3,:) = min(T(3,:),0.0_CUSTOM_REAL)

    ! smooth loading within nucleation patch
    !WARNING : ad hoc for SCEC benchmark TPV10x
    if (RATE_AND_STATE) then
      ! see: Kaneko (2008), appendix B "Rupture Initiation Procedure"
      TxExt(:) = 0.0_CUSTOM_REAL
      TLoad = 1.0_CUSTOM_REAL   ! T_ini
      DTau0 = 1.0_CUSTOM_REAL   ! \Delta \tau_0

      ! time will never be zero. it starts from 1
      timeval = it*bc%dt

      ! function G(t)
      ! see Kaneko (2008), equation (B3):
      !   if 0 < t < T_ini
      !     G(t) = exp( (t - T_ini)^2 / (t^2 - 2 t T_ini)
      !   else
      !     G(t) = 1
      if (timeval <= TLoad) then
        GLoad = exp( (timeval-TLoad)*(timeval-Tload) / (timeval*(timeval-2.0_CUSTOM_REAL*TLoad)) )
      else
        GLoad = 1.0_CUSTOM_REAL
      endif
      ! Kaneko (2008), equation (B1): \Delta \tau = \Delta \tau_0 * F(x,z) * G(t)
      ! the geometry and values of function F(x,z) have been pre-computed for a case specific nucleation patch
      TxExt(:) = DTau0 * bc%Fload(:) * GLoad

      ! adds horizontal shear traction perturbation
      T(1,:) = T(1,:) + TxExt(:)
    endif

    ! norm of shear fault traction
    Tstick(:) = sqrt( T(1,:)*T(1,:) + T(2,:)*T(2,:))

    if (.not. RATE_AND_STATE) then
      ! slip weakening friction

      ! update slip state variable
      ! WARNING: during opening the friction state variable should not evolve
      theta_old(:) = bc%swf%theta(:)
      call swf_update_state(bc%D,dD,bc%V,bc%swf)

      ! update friction coefficient (using slip weakening friction law)
      bc%mu(:) = swf_mu(bc%swf)

      ! combined with time-weakening for nucleation
      if (TWF) then
        timeval = it*bc%dt
        nuc_x   = bc%twf%nuc_x
        nuc_y   = bc%twf%nuc_y
        nuc_z   = bc%twf%nuc_z
        nuc_r   = bc%twf%nuc_r
        nuc_t0  = bc%twf%nuc_t0
        nuc_v   = bc%twf%nuc_v
        do i = 1,bc%nglob
            dist = ((bc%coord(1,i)-nuc_x)**2 + (bc%coord(2,i)-nuc_y)**2 + (bc%coord(3,i)-nuc_z)**2)**0.5
            if (dist <= nuc_r) then
                tw_r     = timeval * nuc_v
                coh_size = nuc_t0  * nuc_v
                if (dist <= tw_r - coh_size) then
                    bc%mu(i) = min(bc%mu(i), bc%swf%mud(i))
                else if (dist > tw_r - coh_size .and. dist <= tw_r ) then
                    bc%mu(i) = min(bc%mu(i), bc%swf%mud(i) + (dist-(tw_r-coh_size))/coh_size*(bc%swf%mus(i)-bc%swf%mud(i)))
                endif
            endif
        enddo
      endif

      ! TPV16 benchmark
      if (TPV16) then
        ! fixes friction coefficient to be dynamic friction coefficient when rupture time is over
        where (bc%swf%T(:) <= it*bc%dt) bc%mu(:) = bc%swf%mud(:)
      endif

      ! updates fault strength
      strength(:) = -bc%mu(:) * min(T(3,:),0.0_CUSTOM_REAL) + bc%swf%C(:)

      ! solves for shear stress
      Tnew(:) = min(Tstick(:),strength(:))

    else
      ! rate and state friction

      !JPA the solver below can be refactored into a loop with two passes
      !
      ! see: Kaneko (2008), explanation of steps 4 and 6 in section 2.3,
      !      and compare against the alternative first-order expansion given by equation (24)

      ! first pass
      theta_old(:) = bc%rsf%theta(:)
      call rsf_update_state(Vf_old,bc%dt,bc%rsf)

      do i = 1,bc%nglob
        Vf_new(i) = rtsafe(0.0_CUSTOM_REAL,Vf_old(i)+5.0_CUSTOM_REAL,1e-5_CUSTOM_REAL,Tstick(i),-T(3,i),bc%Z(i),bc%rsf%f0(i), &
                           bc%rsf%V0(i),bc%rsf%a(i),bc%rsf%b(i),bc%rsf%L(i),bc%rsf%theta(i),bc%rsf%StateLaw)
      enddo

      ! second pass
      bc%rsf%theta(:) = theta_old(:)
      tmp_Vf(:) = 0.5_CUSTOM_REAL*(Vf_old(:) + Vf_new(:))
      call rsf_update_state(tmp_Vf,bc%dt,bc%rsf)

      do i = 1,bc%nglob
        Vf_new(i) = rtsafe(0.0_CUSTOM_REAL,Vf_old(i)+5.0_CUSTOM_REAL,1e-5_CUSTOM_REAL,Tstick(i),-T(3,i),bc%Z(i),bc%rsf%f0(i), &
                           bc%rsf%V0(i),bc%rsf%a(i),bc%rsf%b(i),bc%rsf%L(i),bc%rsf%theta(i),bc%rsf%StateLaw)
      enddo

      Tnew(:) = Tstick(:) - bc%Z(:) * Vf_new(:)
    endif

    Tstick(:) = max(Tstick(:),1.0_CUSTOM_REAL) ! to avoid division by zero

    T(1,:) = Tnew(:) * T(1,:)/Tstick(:)
    T(2,:) = Tnew(:) * T(2,:)/Tstick(:)

    ! Save total tractions
    bc%T(:,:) = T(:,:)

    ! Subtract initial stress (to have relative stress on the fault)
    T(:,:) = T(:,:) - bc%T0(:,:)

    if (RATE_AND_STATE) T(1,:) = T(1,:) - TxExt(:)
    !JPA: this eliminates the effect of TxExt on the equations of motion. Why is it needed?

    ! Update slip acceleration da=da_free-T/(0.5*dt*Z)
    dA(1,:) = dA(1,:) - T(1,:)/(bc%Z(:) * half_dt)
    dA(2,:) = dA(2,:) - T(2,:)/(bc%Z(:) * half_dt)
    dA(3,:) = dA(3,:) - T(3,:)/(bc%Z(:) * half_dt)

    ! Update slip and slip rate, in fault frame
    bc%D(:,:) = dD(:,:)
    bc%V(:,:) = dV(:,:) + half_dt*dA(:,:)

    ! Rotate tractions back to (x,y,z) frame
    T(:,:) = rotate(bc,T,-1)

    ! Add boundary term B*T to M*a
    call add_BT(bc,MxA,T)

    !-- intermediate storage of outputs --
    Vf_new = sqrt(bc%V(1,:)*bc%V(1,:) + bc%V(2,:)*bc%V(2,:))
    if (.not. RATE_AND_STATE) then
      theta_new(:) = bc%swf%theta(:)
      dc(:) = bc%swf%Dc(:)
    else
      theta_new(:) = bc%rsf%theta(:)
      dc(:) = bc%rsf%L(:)
    endif

    call store_dataXZ(bc%dataXZ, strength, theta_old, theta_new, dc, &
                      Vf_old, Vf_new, it*bc%dt,bc%dt)

    call store_dataT(bc%dataT,bc%D,bc%V,bc%T,it)

    if (RATE_AND_STATE) then
      ! adds storage of state
      do ipoin = 1,bc%dataT%npoin
        iglob = bc%dataT%iglob(ipoin)
        if (bc%rsf%StateLaw == 1) then
          ! ageing law
          bc%dataT%dat(8,ipoin,it) = log10(theta_new(iglob))
        else
          ! slip law
          bc%dataT%dat(8,ipoin,it) = theta_new(iglob)
        endif
      enddo
    endif

    !-- outputs --
    ! write dataT every NTOUT time step or at the end of simulation
    if (mod(it,NTOUT) == 0 .or. it == NSTEP) call SCEC_write_dataT(bc%dataT)
  endif

  ! note: this stage of the routine must be reached by all processes,
  !       otherwise the MPI gather calls won't succeed and the run gets stuck.

  ! write dataXZ every NSNAP time step
  if (mod(it,NSNAP) == 0) then
    if (PARALLEL_FAULT) then
      ! collects data from all processes
      call gather_dataXZ(bc)
      ! main process writes output file
      if (myrank == 0) call write_dataXZ(bc%dataXZ_all,it,iflt)
    else
      ! fault in single slice
      if (bc%nspec > 0) call write_dataXZ(bc%dataXZ,it,iflt)
    endif
  endif

  ! final output
  if (it == NSTEP) then
    if (.not. PARALLEL_FAULT) then
      call SCEC_Write_RuptureTime(bc%dataXZ,iflt)
    else
      if (myrank == 0) call SCEC_Write_RuptureTime(bc%dataXZ_all,iflt)
    endif
  endif

  end subroutine BC_DYNFLT_set3d

!===============================================================

  subroutine swf_init(f,mu,coord,IIN_PAR)

  use constants, only: HUGEVAL
  implicit none

  type(swf_type), intent(out) :: f
  real(kind=CUSTOM_REAL), intent(out)  :: mu(:)
  real(kind=CUSTOM_REAL), intent(in)  :: coord(:,:)
  integer, intent(in) :: IIN_PAR

  integer :: nglob,ier
  real(kind=CUSTOM_REAL) :: mus,mud,dc,C,T
  integer :: nmus,nmud,ndc,nC,nForcedRup,weakening_kind

  NAMELIST / SWF / mus,mud,dc,nmus,nmud,ndc,C,T,nC,nForcedRup,weakening_kind

  nglob = size(mu)

  ! static friction coefficient
  allocate( f%mus(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1370')
  ! dynamic friction coefficient
  allocate( f%mud(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1371')
  ! critical slip distance (aka slip-weakening distance)
  allocate( f%Dc(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1372')
  ! fault state variable theta (magnitude of accumulated slip on fault)
  allocate( f%theta(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1373')
  ! cohesion
  allocate( f%C(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1374')
  ! (forced) rupture time
  allocate( f%T(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1375')

  ! WARNING: if V_HEALING is negative we turn off healing
  f%healing = (V_HEALING > 0.0_CUSTOM_REAL)

  mus = 0.6_CUSTOM_REAL
  mud = 0.1_CUSTOM_REAL
  dc = 1.0_CUSTOM_REAL
  C = 0.0_CUSTOM_REAL
  T = HUGEVAL

  nmus = 0
  nmud = 0
  ndc  = 0
  nC = 0
  nForcedRup = 0
  weakening_kind = 1

  read(IIN_PAR, nml=SWF)

  f%mus(:) = mus  ! static friction coefficient
  f%mud(:) = mud  ! dynamic friction coefficient
  f%Dc(:)  = dc   ! critical slip distance
  f%C(:)   = C    ! cohesion
  f%T(:)   = T    ! (forced) rupture time
  f%kind   = weakening_kind

  call init_2d_distribution(f%mus,coord,IIN_PAR,nmus)
  call init_2d_distribution(f%mud,coord,IIN_PAR,nmud)
  call init_2d_distribution(f%Dc ,coord,IIN_PAR,ndc)
  call init_2d_distribution(f%C  ,coord,IIN_PAR,nC)
  call init_2d_distribution(f%T  ,coord,IIN_PAR,nForcedRup)

  f%theta(:) = 0.0_CUSTOM_REAL

  mu(:) = swf_mu(f)

  end subroutine swf_init

!===============================================================

  subroutine twf_init(f,IIN_PAR)

  implicit none

  type(twf_type), intent(out) :: f
  integer, intent(in) :: IIN_PAR

  integer :: ier

  real(kind=CUSTOM_REAL) :: nuc_x, nuc_y, nuc_z, nuc_r, nuc_t0, nuc_v
  NAMELIST / TWF / nuc_x, nuc_y, nuc_z, nuc_r,nuc_t0,nuc_v

  nuc_x  = 0.0_CUSTOM_REAL
  nuc_y  = 0.0_CUSTOM_REAL
  nuc_z  = 0.0_CUSTOM_REAL

  nuc_r  = 0.0_CUSTOM_REAL
  nuc_t0 = 0.0_CUSTOM_REAL
  nuc_v  = 0.0_CUSTOM_REAL

  read(IIN_PAR, nml=TWF,iostat=ier)
  if (ier /= 0) write(*,*) 'TWF not found in Par_file_faults.'

  f%nuc_x  = nuc_x
  f%nuc_y  = nuc_y
  f%nuc_z  = nuc_z

  f%nuc_r  = nuc_r
  f%nuc_t0 = nuc_t0
  f%nuc_v  = nuc_v

  end subroutine twf_init


!---------------------------------------------------------------------

  subroutine swf_update_state(dold,dnew,vold,f)

  implicit none

  real(kind=CUSTOM_REAL), dimension(:,:), intent(in) :: vold,dold,dnew
  type(swf_type), intent(inout) :: f

  real(kind=CUSTOM_REAL) :: vnorm
  integer :: k,npoin

  ! fault state variable theta (magnitude of accumulated slip on fault)
  ! accumulates fault slip
  f%theta(:) = f%theta(:) + sqrt( (dold(1,:)-dnew(1,:))**2 + (dold(2,:)-dnew(2,:))**2)

  ! fault healing
  if (f%healing) then
    npoin = size(vold,2)
    do k = 1,npoin
      vnorm = sqrt(vold(1,k)**2 + vold(2,k)**2)
      ! velocity below "critical" healing velocity -> no more slip on fault, i.e., fault is "healing"
      if (vnorm < V_HEALING) f%theta(k) = 0.0_CUSTOM_REAL
    enddo
  endif

  end subroutine swf_update_state

!---------------------------------------------------------------------

  function swf_mu(f) result(mu)

  implicit none

  type(swf_type), intent(in) :: f
  real(kind=CUSTOM_REAL) :: mu(size(f%theta))

  if (f%kind == 1) then
  ! slip weakening law
  !
  ! for example: Galvez, 2014, eq. (8)
  !              also Ida, 1973; Palmer & Rice 1973; Andrews 1976; ..
      mu(:) = f%mus(:) - (f%mus(:)-f%mud(:)) * min(f%theta(:)/f%Dc(:), 1.0_CUSTOM_REAL)
  else
  !-- exponential slip weakening:
      mu(:) = f%mud(:) - (f%mud(:)-f%mus(:)) * exp(-f%theta(:)/f%Dc(:))
  endif

  end function swf_mu


!=====================================================================

  subroutine fault_rsf_swf_init_GPU()

  use specfem_par, only: Fault_pointer

  implicit none

  type(bc_dynandkinflt_type),pointer :: bc
  type(rsf_type),pointer :: f
  type(swf_type),pointer :: g
  integer :: ifault

  ! sets up fault arrays on gpu
  do ifault = 1,Nfaults
    bc => faults(ifault)

    f => bc%rsf
    g => bc%swf

    ! checks if fault pointers have been created and allocated
    if (associated(f)) then
      ! rate and state friction simulation

      ! checks feature
      if (RSF_SLIP_LAW_TYPE /= 1) stop 'Fault slip law from Kaneko (2008) not implemented yet'

      ! copies arrays to GPU
      ! (ifault - 1) because in C language, array index start from 0
      call transfer_rsf_data_todevice(Fault_pointer, ifault-1, bc%nglob, bc%Fload, &
                                      f%V0,f%f0,f%V_init,f%a,f%b,f%L,f%theta,f%T,f%C,f%fw,f%Vw,f%StateLaw)
    else if (associated(g)) then
      ! slip weakening friction simulation

      ! checks feature
      if (g%healing) stop 'Fault healing for slip weakening friction not implemented yet on GPU'

      ! copies arrays to GPU
      call transfer_swf_data_todevice(Fault_pointer, ifault-1, bc%nglob, &
                                      g%Dc,g%mus,g%mud,g%T,g%C,g%theta)
    endif
  enddo

  end subroutine fault_rsf_swf_init_GPU

!---------------------------------------------------------------------

  subroutine rsf_init(f,T0,V,nucFload,coord,IIN_PAR)

  use constants, only: HUGEVAL,TWO,HALF,ONE
  implicit none

  type(rsf_type), intent(out) :: f
  real(kind=CUSTOM_REAL)  :: T0(:,:)
  real(kind=CUSTOM_REAL), intent(inout) :: V(:,:)
  real(kind=CUSTOM_REAL), intent(in) :: coord(:,:)
  real(kind=CUSTOM_REAL), pointer :: nucFload(:)
  integer, intent(in) :: IIN_PAR

  real(kind=CUSTOM_REAL) :: V0,f0,a,b,L,theta_init,V_init,fw,Vw, C,T
  integer :: nV0,nf0,na,nb,nL,nV_init,ntheta_init,nfw,nVw, nC,nForcedRup
  real(kind=CUSTOM_REAL) :: Fload
  integer :: nFload
!  real(kind=CUSTOM_REAL), dimension(:,:), allocatable :: init_vel
  integer :: nglob,ier
  integer :: InputStateLaw = 1 ! By default using aging law: 1=ageing law, 2=slip law

  NAMELIST / RSF / V0,f0,a,b,L,V_init,theta_init,nV0,nf0,na,nb,nL,nV_init,ntheta_init, &
                   C,T,nC,nForcedRup,Vw,fw,nVw,nfw,InputStateLaw
  NAMELIST / ASP / Fload,nFload

  nglob = size(coord,2)

  ! rate and state friction
  f%StateLaw = InputStateLaw      ! state-variable evolution law: 1 == ageing law, 2 == slip law

  ! reference slip velocity
  allocate( f%V0(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1376')
  ! reference friction coefficient f0
  allocate( f%f0(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1377')
  ! constitutive parameter a
  allocate( f%a(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1378')
  ! constitutive parameter b
  allocate( f%b(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1379')
  ! characteristic slip distance for state evolution
  allocate( f%L(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1380')
  ! initial slip velocity (at time 0)
  allocate( f%V_init(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1381')
  ! fault state variable theta
  allocate( f%theta(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1382')
  ! cohesion
  allocate( f%C(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1383')
  ! (forced) rupture time
  allocate( f%T(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1384')
  ! SCEC slip friction law parameter: "weakening"(?) friction coefficient
  allocate( f%fw(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1385')
  ! SCEC slip friction law parameter: "weakening"(?) slip rate
  allocate( f%Vw(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1386')

  V0 = 1.e-6_CUSTOM_REAL
  f0 = 0.6_CUSTOM_REAL
  a = 0.0080_CUSTOM_REAL  !0.0080_CUSTOM_REAL
  b = 0.0040_CUSTOM_REAL  !0.0120_CUSTOM_REAL
  L = 0.0135_CUSTOM_REAL
  V_init = 1.e-12_CUSTOM_REAL
  theta_init = 1.084207680000000e+09_CUSTOM_REAL
  C = 0.0_CUSTOM_REAL
  T = HUGEVAL
  fw = 0.2_CUSTOM_REAL
  Vw = 0.1_CUSTOM_REAL

  nV0 = 0
  nf0 = 0
  na = 0
  nb = 0
  nL = 0
  nV_init = 0
  ntheta_init = 0
  nC = 0
  nForcedRup = 0
  nfw = 0
  nVw = 0

  ! reads in rate and state friction parameters
  read(IIN_PAR, nml=RSF)

  f%V0(:) = V0              ! reference slip velocity
  f%f0(:) = f0              ! reference friction coefficient
  f%a(:) = a                ! constitutive parameter a
  f%b(:) = b                ! constitutive parameter a
  f%L(:) = L                ! characteristic slip distance
  f%V_init(:) = V_init      ! initial slip velocity
  f%theta(:) = theta_init   ! initial state
  f%C(:)  = C               ! cohesion
  f%T(:)  = T               ! (forced) rupture time
  f%fw(:) = fw              ! SCEC slip friction law parameter: "weakening"(?) friction coefficient
  f%Vw(:) = Vw              ! SCEC slip friction law parameter: "weakening"(?) slip rate

  call init_2d_distribution(f%V0,coord,IIN_PAR,nV0)
  call init_2d_distribution(f%f0,coord,IIN_PAR,nf0)
  call init_2d_distribution(f%a,coord,IIN_PAR,na)
  call init_2d_distribution(f%b,coord,IIN_PAR,nb)
  call init_2d_distribution(f%L,coord,IIN_PAR,nL)
  call init_2d_distribution(f%V_init,coord,IIN_PAR,nV_init)
  call init_2d_distribution(f%theta,coord,IIN_PAR,ntheta_init)
  call init_2d_distribution(f%C,coord,IIN_PAR,nC)
  call init_2d_distribution(f%T,coord,IIN_PAR,nForcedRup)
  call init_2d_distribution(f%fw,coord,IIN_PAR,nfw)
  call init_2d_distribution(f%Vw,coord,IIN_PAR,nVw)

!!$    ! WARNING : Not general enough
!!$    vel = 0._CUSTOM_REAL
!!$    nglob_bulk = size(vel,2)
!!$    allocate(init_vel(3,nglob_bulk))
!!$    init_vel = 0._CUSTOM_REAL
!!$    init_vel(1,bc%ibulk1) =  -f%V_init/2._CUSTOM_REAL
!!$    init_vel(1,bc%ibulk2) =  f%V_init/2._CUSTOM_REAL
!!$    where(ystore > 0) init_vel(1,:) = -V_init/2._CUSTOM_REAL
!!$    where(ystore < 0) init_vel(1,:) = V_init/2._CUSTOM_REAL
!!$    !init_vel = rotate(bc,init_vel,-1) ! directly assigned in global coordinates here as it is a simplified case
!!$    vel = vel + init_vel

  ! WARNING: The line below scratches an earlier initialization of theta through theta_init
  !          We should implement it as an option for the user
  if (TPV16) then
    if (f%stateLaw == 1) then
      ! ageing law
      f%theta(:) = f%L(:) / f%V0(:) &
                * exp( ( f%a(:) * log(TWO * sinh(-sqrt(T0(1,:)**2 + T0(2,:)**2)/T0(3,:)/f%a(:))) &
                         - f%f0(:) - f%a(:) * log(f%V_init(:)/f%V0(:)) ) &
                       / f%b(:) )
    else
      ! slip law
      f%theta(:) =  f%a(:) * log(TWO * f%V0(:) / f%V_init(:) * sinh(-sqrt(T0(1,:)**2 + T0(2,:)**2)/T0(3,:)/f%a(:)))
    endif
  endif

  ! WARNING : ad hoc for SCEC benchmark TPV10x
  allocate( nucFload(nglob) ,stat=ier)
  if (ier /= 0) call exit_MPI_without_rank('error allocating array 1387')
  nucFload(:) = 0.0_CUSTOM_REAL

  Fload = 0.0_CUSTOM_REAL
  nFload = 0

  ! reads in asperity parameters
  read(IIN_PAR, nml=ASP)

  nucFload(:) = Fload

  call init_2d_distribution(nucFload,coord,IIN_PAR,nFload)

  ! WARNING: the line below is only valid for pure strike-slip faulting
  V(1,:) = f%V_init(:)

  if (TPV10X) then
    call make_TPV10X_BoundaryRateStrengtheningLayer()
  endif

  if (RSF_HETE) then
    call RSF_HETE_init()
  endif

  contains

  !-------

    subroutine RSF_HETE_init()

    use constants, only: IIN_FLT

    implicit none

    ! local parameters
    integer :: si,ier, ipar
    real(kind=CUSTOM_REAL),  allocatable :: sloc_str(:), &
         sloc_dip(:),ssigma0(:),stau0_str(:),stau0_dip(:),sV0(:), &
         sf0(:),sa(:),sb(:),sL(:),sV_init(:),stheta(:),sC(:)
    real(kind=CUSTOM_REAL) :: minX, ssiz_str,ssiz_dip
    integer :: snum_cell_str,snum_cell_dip,snum_cell_all

    integer, parameter :: IIN_NUC = IIN_FLT

    open(unit=IIN_NUC,file='../DATA/rsf_hete_input_file.txt',status='old',iostat=ier)
    if (ier /= 0) then
      print *,'Error opening file ','../DATA/rsf_hete_input_file.txt'
      print *,'Please check setup for RSF HETE...'
      stop 'Error opening file rsf_hete_input_file.txt'
    endif

    read(IIN_NUC,*) snum_cell_str,snum_cell_dip,ssiz_str,ssiz_dip

    snum_cell_all = snum_cell_str*snum_cell_dip
    write(*,*) snum_cell_str,snum_cell_dip,ssiz_str,ssiz_dip

    allocate( sloc_str(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1388')
    allocate( sloc_dip(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1389')
    allocate( ssigma0(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1390')
    allocate( stau0_str(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1391')
    allocate( stau0_dip(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1392')
    allocate( sV0(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1393')
    allocate( sf0(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1394')
    allocate( sa(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1395')
    allocate( sb(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1396')
    allocate( sL(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1397')
    allocate( sV_init(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1398')
    allocate( stheta(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1399')
    allocate( sC(snum_cell_all) ,stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1400')

    do ipar = 1,snum_cell_all
      read(IIN_NUC,*) sloc_str(ipar),sloc_dip(ipar),ssigma0(ipar),stau0_str(ipar),stau0_dip(ipar), &
                      sV0(ipar),sf0(ipar),sa(ipar),sb(ipar),sL(ipar), &
                      sV_init(ipar),stheta(ipar),sC(ipar)
    enddo
    close(IIN_NUC)

    minX = minval(coord(1,:))
    write(*,*) 'RSF_HETE nglob= ', nglob, 'num_cell_all= ', snum_cell_all
    write(*,*) 'minX = ', minval(coord(1,:)), 'minZ = ', minval(coord(3,:))
    write(*,*) 'maxX = ', maxval(coord(1,:)), 'maxZ = ', maxval(coord(3,:))
    write(*,*) 'minXall = ', minval(sloc_str(:)), 'minZall = ', minval(sloc_dip(:))
    write(*,*) 'maxXall = ', maxval(sloc_str(:)), 'maxZall = ', maxval(sloc_dip(:))

    do si = 1,nglob
      ! WARNING: nearest neighbor interpolation
      ipar = minloc( (sloc_str(:)-coord(1,si))**2 + (sloc_dip(:)-coord(3,si))**2 , 1)
      !loc_dip is negative of Z-coord

      T0(3,si) = -ssigma0(ipar)     ! normal stress
      T0(1,si) = stau0_str(ipar)    ! shear stress strike-direction
      T0(2,si) = stau0_dip(ipar)    ! shear stress dip-direction

      f%V0(si) = sV0(ipar)          ! reference slip velocity
      f%f0(si) = sf0(ipar)          ! reference frictional coefficient
      f%a(si) = sa(ipar)            ! constitutive parameter a
      f%b(si) = sb(ipar)            ! constitutive parameter a
      f%L(si) = sL(ipar)            ! characteristic slip distance
      f%V_init(si) = sV_init(ipar)  ! initial slip velocity
      f%theta(si) = stheta(ipar)    ! initial state
      f%C(si) = sC(ipar)            ! cohesion
    enddo

    end subroutine RSF_HETE_init

    !--------

    subroutine make_TPV10X_BoundaryRateStrengtheningLayer()

! adding a rate strengthening layer at the boundary of a fault for TPV10X
! see http://scecdata.usc.edu/cvws/download/uploadTPV103.pdf for more details

    implicit none
    real(kind=CUSTOM_REAL) :: W1,W2,w,hypo_z
    real(kind=CUSTOM_REAL) :: x,z
    logical :: c1,c2,c3,c4
    real(kind=CUSTOM_REAL) :: b11,b12,b21,b22,B1,B2
    integer :: i !,nglob_bulk

    ! TPV10x description:
    ! The central portion of the fault, -W < x < W, 0 < y < W , with W = 15 km,
    ! is velocity-weakening. A transition layer of width w = 3 km in which the frictional
    ! properties continuously change from velocity-weakening to velocity-strengthening
    ! surrounds the central velocity-weakening region of the fault. Outside of the transition
    ! region, the fault is velocity-strengthening.

    W1 = 15000.0_CUSTOM_REAL
    W2 = 7500.0_CUSTOM_REAL
    w = 3000.0_CUSTOM_REAL
    hypo_z = -7500.0_CUSTOM_REAL

    do i = 1,nglob
      x = coord(1,i)
      z = coord(3,i)

      ! flags for boundary
      c1 = abs(x) < W1+w
      c2 = abs(x) > W1
      c3 = abs(z-hypo_z) < W2+w
      c4 = abs(z-hypo_z) > W2

      ! update frictional properties
      if ((c1 .and. c2 .and. c3) .or. (c3 .and. c4 .and. c1)) then
        ! inside fault region
        if (c1 .and. c2) then
          ! transition layer
          b11 = w/(abs(x)-W1-w)
          b12 = w/(abs(x)-W1)
          B1 = HALF * (ONE + tanh(b11 + b12))
        else if (abs(x) <= W1) then
          ! central portion of fault
          B1 = 1.0_CUSTOM_REAL
        else
          B1 = 0.0_CUSTOM_REAL
        endif

        if (c3 .and. c4) then
          ! transition layer
          b21 = w/(abs(z-hypo_z)-W2-w)
          b22 = w/(abs(z-hypo_z)-W2)
          B2 = HALF * (ONE + tanh(b21 + b22))
        else if (abs(z-hypo_z) <= W2) then
          ! central portion of fault
          B2 = 1.0_CUSTOM_REAL
        else
          B2 = 0.0_CUSTOM_REAL
        endif
        ! update slip-weakening
        f%a(i) = 0.008 + 0.008 * (ONE - B1*B2)
        f%Vw(i) = 0.1 + 0.9 * (ONE - B1*B2)

      else if (abs(x) <= W1 .and. abs(z-hypo_z) <= W2) then
        ! central portion of fault
        f%a(i) = 0.008
        f%Vw(i) = 0.1_CUSTOM_REAL
      else
        ! outside of fault
        f%a(i) = 0.016
        f%Vw(i) = 1.0_CUSTOM_REAL
      endif
    enddo

    end subroutine make_TPV10X_BoundaryRateStrengtheningLayer

  end subroutine rsf_init

!---------------------------------------------------------------------
!!$! Rate and state friction coefficient
!!$function rsf_mu(f,V) result(mu)
!!$
!!$  type(rsf_type), intent(in) :: f
!!$  real(kind=CUSTOM_REAL), dimension(:), intent(in) :: V
!!$  real(kind=CUSTOM_REAL) :: mu(size(V))
!!$  double precision :: arg
!!$
!!$  arg = V/TWO/f%V0 * exp((f%f0 + f%b*log(f%theta*f%V0/f%L))/f%a )
!!$
!!$  mu = f%a * asinh_slatec( arg ) ! Regularized
!!$
!!$end function rsf_mu

!---------------------------------------------------------------------

  subroutine rsf_update_state(V,dt_real,f)

  use constants, only: ONE,HALF,TWO
  implicit none

  real(kind=CUSTOM_REAL), dimension(:), intent(in) :: V
  type(rsf_type), intent(inout) :: f
  real(kind=CUSTOM_REAL), intent(in) :: dt_real

  real(kind=CUSTOM_REAL) :: vDtL(size(V))
  real(kind=CUSTOM_REAL) :: f_ss(size(V)),theta_ss(size(V)),f_LV(size(V))

  ! state variable evolution
  !
  ! see: Kaneko (2008), equation (19) for ageing law and equation (20) for slip law

  ! common factor
  vDtL(:) = V(:) * dt_real / f%L(:)

  ! note: assumes that vDTL is strictly positive ( >= 0), since V >= 0, dt > 0 and L > 0
  if (any(vDtL(:) < 0.0_CUSTOM_REAL)) stop 'Invalid negative factor found in rate and state friction law'

  ! state update
  if (f%StateLaw == 1) then
    ! ageing law
    ! see: Kaneko (2008), equation (19)
    !      theta_n+1 = theta_n * exp( - V_n * dt / L) + L/V_n ( 1 - exp(- V_n * dt / L))
    where(vDtL(:) > 1.e-5_CUSTOM_REAL)
      ! update theta_n+1
      f%theta(:) = f%theta(:) * exp(-vDtL(:)) + f%L(:)/V(:) * (ONE - exp(-vDtL(:)))
    elsewhere
      ! faster computation for small values
      !
      ! note: Lapusta, N. and. Y. Liu (2009),
      !       Three-dimensional boundary integral modeling of spontaneous earthquake sequences and aseismic slip,
      !       JGR, 114, B09303, doi:10.1029/2008JB005934
      !
      !       in Appendix B and equation (B7) this case is used to avoid issues when V_n dt L becomes very small.
      !       however, their update theta_n+1 uses the log(..) since instead of updating state variable theta directly,
      !       they use the quantity \phi = log(V_0 theta / L) and a corresponding modified slip evolution law.
      !
      !       thus, we might not need this special case for small values and could use the exp(..) directly,
      !       but it might be slightly faster to use the power series expansion here.
      !
      ! Power series for exponential function:
      !   exp(x) = 1 + x + x**2/2 + x**3/6 ..
      ! for small x, one can ignore the high-order terms and assume
      !   exp(x) ~ 1 + x + x**2/2
      ! thus,
      !   1 - exp(- V_n * dt / L) = 1 - (1 - V_n * dt /L + 1/2 (V_n * dt /L)**2 ) = V_n * dt / L - 1/2 (V_n * dt /L)**2
      ! and update becomes
      !   theta_n+1 = theta_n * exp( - V_n * dt / L) + L/V_n ( V_n * dt / L  - 1/2 (V_n * dt /L)**2 )
      !             = theta_n * exp( - V_n * dt / L) +  ( dt - 1/2 V_n * dt**2 / L )
      !             = theta_n * exp( - V_n * dt / L) +  dt ( 1 - 1/2 V_n * dt / L )
      f%theta(:) = f%theta(:) * exp(-vDtL(:)) + dt_real * ( ONE - HALF*vDtL(:) )
    endwhere

  else
    ! slip law
    !
    if (RSF_SLIP_LAW_TYPE == 1) then
      ! default, strong rate-weakening:
      !
      ! we use a slip law as described by SCEC TPV103/104 benchmark
      ! https://strike.scec.org/cvws/download/SCEC_validation_slip_law.pdf
      !
      ! friction coefficient f(V,theta) = a arcsinh[ V/(2 V_0) exp( theta/a ) ]
      ! state evolution:
      !      dtheta/dt = - V/L [ theta - theta_ss(V) ]              eq. (3)
      !    and
      !      theta_ss(V) = a ln( 2 V_0/V sinh(f_ss(V)/a) )          eq. (4)
      !
      ! with theta the state variable, theta_ss the steady-state value
      ! and f_ss the steady-state friction coefficient.
      !
      ! the steady-state friction coefficient f_ss(V) follows the friction law:
      !     f_ss(V) = f_w + [ f_LV(V) - f_w ]/[1 + (V/V_w)**8]**(1/8)             eq. (5)
      !
      ! with a low-velocity steady-state friction coefficient f_LV(V) as:
      !     f_LV(V) = f_0 - (b - a) ln(V/V_0)                                     eq. (6)
      !
      ! using friction law parameters f_w a "weakening"(?) friction coefficient and V_w a "weakening"(?) slip rate

      where(V(:) /= 0.0_CUSTOM_REAL)  ! todo: comparison of float against zero, should add numerical tolerance
        ! low-velocity friction coefficient f_LV:
        !     f_LV = f_0 - (b - a) ln( V_n / V_0 )
        ! according to eq. (6)
        f_LV(:) = f%f0(:) - (f%b(:) - f%a(:))*log(V(:)/f%V0(:))

        ! steady-state friction:
        !     f_ss = f_w + ( f_LV - f_w) / (1 + (V_n/V_w)^8 )^{1/8)
        ! according to eq. (5)
        f_ss(:) = f%fw(:) + (f_LV(:) - f%fw(:))/(ONE + (V(:)/f%Vw(:))**8)**0.125

        ! steady-state state variable:
        !   theta_ss = a ln( 2 V_0 / V_n * sinh( f_ss / a ) )
        ! according to eq. (4) above
        theta_ss(:) = f%a(:) * log( TWO*f%V0(:)/V(:) * sinh(f_ss(:)/f%a(:)) )

        ! state variable update:
        !   theta_n+1 = theta_ss + (theta_n - theta_ss ) exp(- V_n * dt / L )
        !
        f%theta(:) = theta_ss(:) + (f%theta(:) - theta_ss(:)) * exp(-vDtL(:))
      elsewhere
        f%theta(:) = f%theta(:)
      endwhere
    else
      ! Kaneko (2008) slip law:
      ! state evolution law
      !     dtheta/dt = - V theta / L  ln(V theta/L)      slip law eq.(14)
      !
      ! uses equation (20) for time stepping:
      !         theta_n+1 = L/V_n ( V_n * theta_n / L )^{ exp(- V_n * dt / L) }
      !
      f%theta(:) = f%L(:)/V(:) * (f%theta(:)*V(:)/f%L(:))**(exp(-vDtL(:)))
    endif
  endif

  end subroutine rsf_update_state


!===============================================================
! OUTPUTS

  subroutine SCEC_Write_RuptureTime(dataXZ,iflt)

  use specfem_par, only: OUTPUT_FILES

  implicit none

  type(dataXZ_type), intent(in) :: dataXZ
  integer, intent(in) :: iflt

  ! local parameters
  integer :: i
  character(len=MAX_STRING_LEN) :: filename
  integer, dimension(8) :: time_values
  integer, parameter :: IOUT_RUP = 121 !WARNING: not very robust. Could instead look for an available ID

  call date_and_time(VALUES=time_values)

  write(filename,'(a,I0)') trim(OUTPUT_FILES)//'/RuptureTime_Fault', iflt

  open(IOUT_RUP,file=trim(filename),status='replace')
  write(IOUT_RUP,*) "# problem=TPV104"
  write(IOUT_RUP,*) "# author=Surendra Nadh Somala"
  write(IOUT_RUP,1000) time_values(2), time_values(3), time_values(1), time_values(5), time_values(6), time_values(7)
  write(IOUT_RUP,*) "# code=SPECFEM3D_Cartesian (split nodes)"
  write(IOUT_RUP,*) "# code_version=1.1"
  write(IOUT_RUP,*) "# element_size=100 m  (*5 GLL nodes)"
  write(IOUT_RUP,*) "# Column #1 = horizontal coordinate, distance along strike (m)"
  write(IOUT_RUP,*) "# Column #2 = vertical coordinate, distance down-dip (m)"
  write(IOUT_RUP,*) "# Column #3 = rupture time (s)"
  write(IOUT_RUP,*) "# "
  write(IOUT_RUP,*) "j k t"
  do i = 1,size(dataXZ%tRUP)
    write(IOUT_RUP,'(3(E15.7))') dataXZ%xcoord(i), -dataXZ%zcoord(i), dataXZ%tRUP(i)
  enddo

  close(IOUT_RUP)

1000 format ( ' # Date = ', i2.2, '/', i2.2, '/', i4.4, '; time = ',i2.2, ':', i2.2, ':', i2.2 )

  end subroutine SCEC_Write_RuptureTime

!-------------------------------------------------------------------------------------------------

  subroutine init_dataXZ(dataXZ,bc)

  use constants, only: PARALLEL_FAULT
  use specfem_par, only: NPROC,myrank

  implicit none

  type(dataXZ_type), intent(inout) :: dataXZ
  type(bc_dynandkinflt_type) :: bc

  integer :: npoin_all,iproc,ier

  dataXZ%npoin = bc%nglob

  if (bc%nglob > 0) then
    allocate(dataXZ%stg(bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1401')
    if (.not. RATE_AND_STATE) then
      dataXZ%sta => bc%swf%theta
    else
      dataXZ%sta => bc%rsf%theta
    endif
    dataXZ%d1 => bc%D(1,:)
    dataXZ%d2 => bc%D(2,:)
    dataXZ%v1 => bc%V(1,:)
    dataXZ%v2 => bc%V(2,:)
    dataXZ%t1 => bc%T(1,:)
    dataXZ%t2 => bc%T(2,:)
    dataXZ%t3 => bc%T(3,:)
    dataXZ%xcoord => bc%coord(1,:)
    dataXZ%ycoord => bc%coord(2,:)
    dataXZ%zcoord => bc%coord(3,:)
    allocate(dataXZ%tRUP(bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1402')
    allocate(dataXZ%tPZ(bc%nglob),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1403')
  else
    ! dummy allocations (for subroutine arguments)
    dataXZ%sta => bc%D(1,:)  ! note: swf or rwf are not allocated when there are no fault elements, thus just a dummy pointer
    dataXZ%d1 => bc%D(1,:)
    dataXZ%d2 => bc%D(2,:)
    dataXZ%v1 => bc%V(1,:)
    dataXZ%v2 => bc%V(2,:)
    dataXZ%t1 => bc%T(1,:)
    dataXZ%t2 => bc%T(2,:)
    dataXZ%t3 => bc%T(3,:)
    dataXZ%xcoord => bc%coord(1,:)
    dataXZ%ycoord => bc%coord(2,:)
    dataXZ%zcoord => bc%coord(3,:)
    allocate(dataXZ%tRUP(1), &
             dataXZ%tPZ(1), &
             dataXZ%stg(1))
  endif
  ! setting up initial rupture time null
  dataXZ%tRUP = 0.0_CUSTOM_REAL
  dataXZ%tPZ  = 0.0_CUSTOM_REAL

  ! for parallel fault
  if (PARALLEL_FAULT) then
    npoin_all = 0
    call sum_all_all_i(bc%nglob,npoin_all)

    ! checks
    if (npoin_all == 0) then
      print *,'Error: no fault points found, please check fault setup'
      call exit_MPI(myrank,'Error no fault points found')
    endif

    bc%dataXZ_all%npoin = npoin_all

    ! only main ranks needs to allocate gathering arrays **_all
    if (myrank == 0) then
      allocate(bc%dataXZ_all%xcoord(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1404')
      allocate(bc%dataXZ_all%ycoord(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1405')
      allocate(bc%dataXZ_all%zcoord(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1406')
      allocate(bc%dataXZ_all%t1(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1407')
      allocate(bc%dataXZ_all%t2(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1408')
      allocate(bc%dataXZ_all%t3(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1409')
      allocate(bc%dataXZ_all%d1(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1410')
      allocate(bc%dataXZ_all%d2(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1411')
      allocate(bc%dataXZ_all%v1(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1412')
      allocate(bc%dataXZ_all%v2(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1413')
      allocate(bc%dataXZ_all%tRUP(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1414')
      allocate(bc%dataXZ_all%tPZ(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1415')
      allocate(bc%dataXZ_all%stg(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1416')
      allocate(bc%dataXZ_all%sta(npoin_all),stat=ier)
      if (ier /= 0) call exit_MPI_without_rank('error allocating array 1417')
    else
      ! dummy allocations (for subroutine arguments)
      bc%dataXZ_all%npoin = 0
      allocate(bc%dataXZ_all%xcoord(1), &
               bc%dataXZ_all%ycoord(1), &
               bc%dataXZ_all%zcoord(1), &
               bc%dataXZ_all%t1(1), &
               bc%dataXZ_all%t2(1), &
               bc%dataXZ_all%t3(1), &
               bc%dataXZ_all%d1(1), &
               bc%dataXZ_all%d2(1), &
               bc%dataXZ_all%v1(1), &
               bc%dataXZ_all%v2(1), &
               bc%dataXZ_all%tRUP(1), &
               bc%dataXZ_all%tPZ(1), &
               bc%dataXZ_all%stg(1), &
               bc%dataXZ_all%sta(1))
    endif

!note: crayftn compiler warns about possible copy which may slow down the code for dataXZ%npoin,dataXZ%xcoord,..
!ftn-1438 crayftn: CAUTION INIT_DATAXZ, File = src/specfem3D/fault_solver_dynamic.f90, Line = 1036, Column = 45
!  This argument produces a possible copy in and out to a temporary variable.

    allocate(bc%npoin_perproc(NPROC),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1418')
    bc%npoin_perproc(:) = 0
    call gather_all_singlei(dataXZ%npoin,bc%npoin_perproc,NPROC)

    allocate(bc%poin_offset(NPROC),stat=ier)
    if (ier /= 0) call exit_MPI_without_rank('error allocating array 1419')
    bc%poin_offset(:) = 0 ! starts with zero offset
    ! starting with iproc 2, sums previous number of points as offset value
    do iproc = 2,NPROC
      bc%poin_offset(iproc) = sum(bc%npoin_perproc(1:iproc-1))
    enddo

    ! gathers all point coordinates for fault on main process
    call gatherv_all_cr(dataXZ%xcoord,dataXZ%npoin,bc%dataXZ_all%xcoord,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
    call gatherv_all_cr(dataXZ%ycoord,dataXZ%npoin,bc%dataXZ_all%ycoord,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
    call gatherv_all_cr(dataXZ%zcoord,dataXZ%npoin,bc%dataXZ_all%zcoord,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  else
    ! dummy allocations
    allocate(bc%npoin_perproc(1), &
             bc%poin_offset(1))
  endif

  end subroutine init_dataXZ

!---------------------------------------------------------------

  subroutine gather_dataXZ(bc)

  use specfem_par, only: NPROC

  implicit none

  type(bc_dynandkinflt_type), intent(inout) :: bc

  ! collects data from all processes onto main process arrays
  call gatherv_all_cr(bc%dataXZ%t1,bc%dataXZ%npoin,bc%dataXZ_all%t1,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%t2,bc%dataXZ%npoin,bc%dataXZ_all%t2,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%t3,bc%dataXZ%npoin,bc%dataXZ_all%t3,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%d1,bc%dataXZ%npoin,bc%dataXZ_all%d1,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%d2,bc%dataXZ%npoin,bc%dataXZ_all%d2,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%v1,bc%dataXZ%npoin,bc%dataXZ_all%v1,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%v2,bc%dataXZ%npoin,bc%dataXZ_all%v2,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%tRUP,bc%dataXZ%npoin,bc%dataXZ_all%tRUP,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%tPZ,bc%dataXZ%npoin,bc%dataXZ_all%tPZ,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%stg,bc%dataXZ%npoin,bc%dataXZ_all%stg,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)
  call gatherv_all_cr(bc%dataXZ%sta,bc%dataXZ%npoin,bc%dataXZ_all%sta,bc%npoin_perproc,bc%poin_offset,bc%dataXZ_all%npoin,NPROC)

  end subroutine gather_dataXZ

!---------------------------------------------------------------

  subroutine store_dataXZ(dataXZ,stg,dold,dnew,dc,vold,vnew,timeval,dt_real)

  implicit none

  type(dataXZ_type), intent(inout) :: dataXZ
  real(kind=CUSTOM_REAL), dimension(:), intent(in) :: stg,dold,dnew,dc,vold,vnew
  real(kind=CUSTOM_REAL), intent(in) :: timeval,dt_real

  integer :: i

  dataXZ%stg = stg

  do i = 1,size(stg)

    ! process zone time = first time when slip = dc  (break down process)
    ! with linear time interpolation
    if (dataXZ%tPZ(i) == 0e0_CUSTOM_REAL) then
      if (dold(i) <= dc(i) .and. dnew(i) >= dc(i)) then
        dataXZ%tPZ(i) = timeval - dt_real * (dnew(i)-dc(i))/(dnew(i)-dold(i))
      endif
    endif

    ! rupture time = first time when slip velocity = V_RUPT
    ! with linear time interpolation
    if (dataXZ%tRUP(i) == 0e0_CUSTOM_REAL) then
      if (vold(i) <= V_RUPT .and. vnew(i) >= V_RUPT) dataXZ%tRUP(i)= timeval - dt_real * (vnew(i)-V_RUPT)/(vnew(i)-vold(i))
    endif

  enddo

  ! note: the other arrays in dataXZ are pointers to arrays in bc
  !       they do not need to be updated here

  end subroutine store_dataXZ

!---------------------------------------------------------------

  subroutine write_dataXZ(dataXZ,itime,iflt)

  use specfem_par, only: OUTPUT_FILES

  implicit none

  type(dataXZ_type), intent(in) :: dataXZ
  integer, intent(in) :: itime,iflt

  ! local parameters
  integer :: ier
  character(len=MAX_STRING_LEN) :: filename
  integer, parameter :: IOUT_SN = 121 !WARNING: not very robust. Could instead look for an available ID

  write(filename,"(a,I0,'_F',I0,'.bin')") trim(OUTPUT_FILES)//'/Snapshot',itime,iflt

  open(unit=IOUT_SN, file=trim(filename), status='replace', form='unformatted',action='write',iostat=ier)
  if (ier /= 0) then
    print *,'Error opening Snapshot file: ',trim(filename)
    stop 'Error opening Snapshot file'
  endif

  write(IOUT_SN) dataXZ%xcoord
  write(IOUT_SN) dataXZ%ycoord
  write(IOUT_SN) dataXZ%zcoord
  write(IOUT_SN) dataXZ%d1
  write(IOUT_SN) dataXZ%d2
  write(IOUT_SN) dataXZ%v1
  write(IOUT_SN) dataXZ%v2
  write(IOUT_SN) dataXZ%t1
  write(IOUT_SN) dataXZ%t2
  write(IOUT_SN) dataXZ%t3
  write(IOUT_SN) dataXZ%sta
  write(IOUT_SN) dataXZ%stg
  write(IOUT_SN) dataXZ%tRUP
  write(IOUT_SN) dataXZ%tPZ

  close(IOUT_SN)

  end subroutine write_dataXZ

!---------------------------------------------------------------


! asinh() function taken from Netlib
! April 1977 edition.  W. Fullerton, C3, Los Alamos Scientific Lab.

! taken from http://www.tddft.org/trac/octopus/browser/trunk/src/asinh.F90?rev=2

! and modified by Dimitri Komatitsch in December 2012 for portability

  double precision function asinh_slatec(x)

  double precision, intent(in) :: x

  integer, parameter :: NSERIES = 39

  double precision, parameter :: asnhcs(NSERIES) = (/ &
   -.12820039911738186343372127359268D+0,  -.58811761189951767565211757138362D-1, &
   +.47274654322124815640725249756029D-2,  -.49383631626536172101360174790273D-3, &
   +.58506207058557412287494835259321D-4,  -.74669983289313681354755069217188D-5, &
   +.10011693583558199265966192015812D-5,  -.13903543858708333608616472258886D-6, &
   +.19823169483172793547317360237148D-7,  -.28847468417848843612747272800317D-8, &
   +.42672965467159937953457514995907D-9,  -.63976084654366357868752632309681D-10, &
   +.96991686089064704147878293131179D-11, -.14844276972043770830246658365696D-11, &
   +.22903737939027447988040184378983D-12, -.35588395132732645159978942651310D-13, &
   +.55639694080056789953374539088554D-14, -.87462509599624678045666593520162D-15, &
   +.13815248844526692155868802298129D-15, -.21916688282900363984955142264149D-16, &
   +.34904658524827565638313923706880D-17, -.55785788400895742439630157032106D-18, &
   +.89445146617134012551050882798933D-19, -.14383426346571317305551845239466D-19, &
   +.23191811872169963036326144682666D-20, -.37487007953314343674570604543999D-21, &
   +.60732109822064279404549242880000D-22, -.98599402764633583177370173440000D-23, &
   +.16039217452788496315232638293333D-23, -.26138847350287686596716134399999D-24, &
   +.42670849606857390833358165333333D-25, -.69770217039185243299730773333333D-26, &
   +.11425088336806858659812693333333D-26, -.18735292078860968933021013333333D-27, &
   +.30763584414464922794065920000000D-28, -.50577364031639824787046399999999D-29, &
   +.83250754712689142224213333333333D-30, -.13718457282501044163925333333333D-30, &
   +.22629868426552784104106666666666D-31 /)

  double precision, parameter :: aln2 = 0.69314718055994530941723212145818D0

! series for asnh       on the interval  0.          to  1.00000d+00
!                                        with weighted error   2.19e-17
!                                         log weighted error  16.66
!                               significant figures required  15.60
!                                    decimal places required  17.31
!

  integer, save :: nterms = 0
  double precision, save :: xmax = 0.d0, sqeps = 0.d0

! taken from http://people.sc.fsu.edu/~jburkardt/f_src/machine/machine.f90
  double precision, parameter :: d1mach_3 = 1.110223024625157D-016

  double precision :: y

  if (nterms == 0) then
    nterms = inits(asnhcs, NSERIES, 0.1d0*d1mach_3)
    sqeps = sqrt(d1mach_3)
    xmax = 1.d0/sqeps
  endif

  y = abs(x)
  if (y <= 1.d0) then
    asinh_slatec = x
    if (y > sqeps) asinh_slatec = x*(1.d0 + csevl(2.d0*x*x-1.d0, asnhcs, nterms))
    return
  endif

  if (y < xmax) asinh_slatec = log(y + sqrt(y**2 + 1.d0))
  if (y >= xmax) asinh_slatec = aln2 + log(y)
  asinh_slatec = sign(asinh_slatec, x)

  contains


! April 1977 version.  W. Fullerton, C3, Los Alamos Scientific Lab.
! Evaluate the n-term Chebyshev series cs at x.  Adapted from
! R. Broucke, Algorithm 446, C.A.C.M., 16, 254 (1973).  Also see Fox
! and Parker, Chebyshev polynomials in numerical analysis, Oxford Press, p.56.
!
!             input arguments --
! x      value at which the series is to be evaluated.
! cs     array of n terms of a Chebyshev series.
!        in evaluating cs, only half the first coefficient is summed.
! n      number of terms in array cs.

    double precision function csevl(x, cs, n)

    implicit none

    integer, intent(in) :: n
    double precision, intent(in) :: x
    double precision, intent(in), dimension(n) :: cs

    integer :: i, ni
    double precision :: b0, b1, b2, twox

    if (n < 1) stop 'Math::csevl: number of terms <= 0'
    if (n > 1000) stop 'Math::csevl: number of terms > 1000'

    if (x < -1.1d0 .or. x > 1.1d0) stop 'Math::csevl: x outside (-1,+1)'

    b1 = 0.d0
    b0 = 0.d0
    twox = 2.d0*x

    do i = 1, n
      b2 = b1
      b1 = b0
      ni = n + 1 - i
      b0 = twox*b1 - b2 + cs(ni)
    enddo

    csevl = 0.5d0 * (b0 - b2)

    end function csevl


! April 1977 version.  W. Fullerton, C3, Los Alamos Scientific Lab.
!
! Initialize the orthogonal series so that inits is the number of terms
! needed to ensure that the error is no larger than eta. Ordinarily, eta
! will be chosen to be one-tenth machine precision.
!
!             input arguments --
! os     array of nos coefficients in an orthogonal series.
! nos    number of coefficients in os.
! eta    requested accuracy of series.

    integer function inits(os, nos, eta)

    implicit none

    integer, intent(in) :: nos
    double precision, intent(in), dimension(nos) :: os
    double precision, intent(in) :: eta

    integer :: i, ii
    double precision :: err

    if (nos < 1) stop 'Math::inits: number of terms <= 0'

    err = 0.d0
    do ii = 1,nos
      i = nos + 1 - ii
      err = err + abs(os(i))
      if (err > eta) exit
    enddo

    !!!!!!!  if (i == nos) print *,'warning: Math::inits: eta may be too small'

    inits = i

    end function inits

  end function asinh_slatec


!---------------------------------------------------------------------

  subroutine funcd(x,fn,df,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)

  use constants, only: ONE,TWO
  implicit none

  double precision,intent(in) :: x
  double precision,intent(out) :: fn,df

  real(kind=CUSTOM_REAL),intent(in) :: Tstick,Seff,Z,f0,V0,a,b,L,theta
  integer,intent(in) :: statelaw

  ! local parameters
  double precision :: arg,xarg  !,fac_asinh

  ! friction coefficient function
  if (statelaw == 1) then
    ! ageing law
    arg = exp((f0+dble(b)*log(V0*theta/L))/a)/TWO/V0
  else
    ! slip law
    if (RSF_SLIP_LAW_TYPE == 1) then
      ! uses SCEC TPV103/104 slip law and modified friction coefficient function
      arg = exp(theta/a)/TWO/V0
    else
      ! Kaneko (2008): same friction coefficient function as for ageing
      !
      ! note: ageing and slip law in principle refer to the state-variable evolution law.
      !       here, we implement the rate and state friction function which is given by
      !       eq.(12) in Kaneko (2008), but, making use of the "improved" regularized friction function given by eq.(15)
      arg = exp((f0+dble(b)*log(V0*theta/L))/a)/TWO/V0
    endif
  endif
  xarg = x * arg

  ! shear strength
  ! based on thermally activated creep model
  !
  ! ageing law:
  !   see: Kaneko (2008), equation (15)
  !     Tau = psi(V, theta)
  !         = a sigma_eff arcsinh[ V/(2 V_0) exp( (f_0 + b ln(V_0 theta / L)) / a ) ]
  !         = a sigma_eff arcsinh[ V  exp( (f_0 + b ln(V_0 theta / L)) / a ) / (2 V_0) ]  (1)
  !
  !   with sigma_eff the effective normal stress.
  !
  ! slip law:
  !   we use a slip law as described by SCEC TPV103/104 benchmark
  !   https://strike.scec.org/cvws/download/SCEC_validation_slip_law.pdf
  !
  !   shear strength of the fault
  !     Tau = f(V,theta) sigma
  !   the product between friction coefficient and normal stress,
  !   and friction coefficient
  !     f(V,theta) = a arcsinh[ V/(2 V_0) exp( theta/a ) ]
  !                = a arcsinh[ V exp( theta/a ) / (2 V_0) ]                              (2)
  !
  ! for the implementation here, compare (1) and (2) to see about the differences.
  ! Seff is the effective normal stress


  ! traction, using fault strength function f(V), as function Tau(V) = sigma * f(V)
  ! see: Kaneko (2008), eq. (21)
  !
  ! note: asinh() is only supported by Fortran 2008 standard and later.
  !       the SPECFEM code tries to support at least Fortran 2003 which has no standard for asinh().
  !       GNU would support asinh() as extension feature, ARM Fortran doesn't support asinh() yet.
  !
  ! using instrinsic asinh() function (most compilers w/ Fortran 2008 implementations support - but not ARM...)
  !fn = Tstick - Z*x - a * Seff * asinh(xarg)
  !
  ! to adhere to std2003 Fortran, we could take this little workaround and use the definition with logarithms:
  !   asinh(x) = ln(x + sqrt(x**2 +1))
  ! where ln() is the natural logarithm:
  !fac_asinh = log(xarg + sqrt(xarg*xarg + 1))
  !fn = Tstick - Z*x - a * Seff * fac_asinh
  !
  ! using netlib's asinh_slatec() implementation
  ! this explicit asinh-function can be used as there is no standard Fortran 2003 implicit function.
  ! (seems slightly faster than the log-definition above...)
  fn = Tstick - Z*x - a * Seff * asinh_slatec(xarg)

  ! traction derivative Tau'(V)
  df = -Z - a * Seff/sqrt(ONE + xarg*xarg) * arg

  end subroutine funcd

!---------------------------------------------------------------------

  function rtsafe(x1,x2,xacc,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)

! root finding by combination of bisection and Newton-Raphson algorithm
! this routine is similar to the Numerical Recipes routine.

  implicit none

  real(kind=CUSTOM_REAL),intent(in) :: x1,x2,xacc
  real(kind=CUSTOM_REAL),intent(in) :: Tstick,Seff,Z,f0,V0,a,b,L,theta
  integer,intent(in) :: statelaw

  double precision :: rtsafe

  ! local parameters
  integer :: j
  !real(kind=CUSTOM_REAL) :: df,dx,dxold,f,fh,fl,temp,xh,xl
  double precision :: df,dx,dxold,f,fh,fl,temp,xh,xl
  integer, parameter :: MAXIT = 200

  call funcd(dble(x1),fl,df,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)
  call funcd(dble(x2),fh,df,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)

  if ((fl > 0.d0 .and. fh > 0.d0) .or. (fl < 0.d0 .and. fh < 0.d0) ) stop 'root must be bracketed in rtsafe'

  if (fl == 0.d0) then        ! todo: comparison of float against zero, should add numerical tolerance
    rtsafe = x1               ! todo: note, original algorithm from Numerical Recipes returns x1 here, the lower bound.
                              !       check if we should return x1 or x2, that is, x1 == 0 and x2 == Vf_old(i)+5.0_CUSTOM_REAL
    return
  else if (fh == 0.d0) then   ! todo: comparison of float against zero, should add numerical tolerance
    rtsafe = x2
    return
  else if (fl < 0.d0) then
    xl = x1
    xh = x2
  else
    xh = x1
    xl = x2
  endif

  rtsafe = 0.5d0 * (x1+x2)
  dxold = abs(x2-x1)
  dx = dxold

  call funcd(rtsafe,f,df,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)

  do j = 1,MAXIT
    if (((rtsafe-xh)*df-f)*((rtsafe-xl)*df-f) > 0.d0 .or. abs(2.d0 * f) > abs(dxold*df)) then
      dxold = dx
      dx = 0.5d0 * (xh-xl)
      rtsafe = xl + dx
      if (xl == rtsafe) return    ! todo: comparison of float against float, should add numerical tolerance
    else
      dxold = dx
      dx = f/df
      temp = rtsafe
      rtsafe = rtsafe - dx
      if (temp == rtsafe) return  ! todo: comparison of float against float, should add numerical tolerance
    endif

    ! check if solution within accuracy xacc
    if (abs(dx) < xacc) return

    call funcd(rtsafe,f,df,Tstick,Seff,Z,f0,V0,a,b,L,theta,statelaw)

    if (f < 0.d0) then
      xl = rtsafe
    else
      xh = rtsafe
    endif
  enddo

  ! case should not occur, might need higher number of iterations?
  stop 'rtsafe exceeding maximum iterations'

  return

  end function rtsafe

!---------------------------------------------------------------------

  subroutine fault_output_synchronize_GPU(it)

  use constants, only: PARALLEL_FAULT
  use specfem_par, only: Fault_pointer,myrank

  implicit none

  integer,intent(in) :: it

  ! local parameters
  type(bc_dynandkinflt_type),pointer :: bc
  integer :: ifault

  do ifault = 1,Nfaults
    bc => faults(ifault)

    ! copies data back to CPU
    call transfer_fault_data_to_host(Fault_pointer, ifault-1, bc%nspec, bc%nglob, bc%D, bc%V, bc%T)

    ! copies dataT back to CPU
    call transfer_dataT_to_host(Fault_pointer, ifault-1, bc%dataT%dat, it)

    ! gather data for whole fault
    if (PARALLEL_FAULT) then
      call gather_dataXZ(bc)
    endif

    ! output data
    call SCEC_write_dataT(bc%dataT)
    if (myrank == 0) call write_dataXZ(bc%dataXZ_all,it,ifault)
  enddo

  end subroutine fault_output_synchronize_GPU

end module fault_solver_dynamic

