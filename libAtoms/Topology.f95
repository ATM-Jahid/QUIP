module topology_module

  use atoms_module,            only: atoms, print, &
                                     add_property, &
                                     read_line, parse_line, &
                                     atoms_n_neighbours, atoms_neighbour, &
                                     distance_min_image
  use clusters_module,         only: bfs_step, add_cut_hydrogens
  use dictionary_module,       only: get_value, value_len
  use linearalgebra_module,    only: find_in_array, find, &
                                     print
  use periodictable_module,    only: ElementName, ElementMass, ElementCovRad
  use structures_module,       only: find_motif
  use system_module,           only: dp, inoutput, initialise, finalise, &
                                     INPUT, OUTPUT, INOUT, &
                                     system_timer, &
                                     optional_default, &
                                     print, print_title, &
                                     string_to_int, string_to_real, round, &
                                     parse_string, read_line, &
                                     operator(//)
#ifndef HAVE_QUIPPY
  use system_module,           only: system_abort
#endif
  use table_module,            only: table, initialise, finalise, &
                                     append, allocate, delete, &
                                     int_part, TABLE_STRING_LENGTH
  use units_module,            only: MASSCONVERT, PI


  implicit none

  private :: next_motif, write_psf_section, create_bond_list
  private :: create_angle_list, create_dihedral_list
  private :: create_improper_list, get_property
#ifdef HAVE_DANNY
  private :: create_pos_dep_charges, calc_fc
#endif

  public  :: delete_bond, &
             write_brookhaven_pdb_file, &
             write_psf_file, &
             create_CHARMM, &
             NONE_RUN, &
             QS_RUN, &
             MM_RUN, &
             QMMM_RUN_CORE, &
             QMMM_RUN_EXTENDED


!parameters for Run_Type
  integer, parameter :: NONE_RUN = -100
  integer, parameter :: QS_RUN = -1
  integer, parameter :: MM_RUN = 0
  integer, parameter :: QMMM_RUN_CORE = 1
  integer, parameter :: QMMM_RUN_EXTENDED = 2

!parameters for the Residue Library
  integer,  parameter, private :: MAX_KNOWN_RESIDUES = 200 !Maximum number of residues in the library
                                                           !(really about 116 at the mo)
  integer,  parameter, private :: MAX_ATOMS_PER_RES = 50   !Maximum number of atoms in one residue
  integer,  parameter, private :: MAX_IMPROPERS_PER_RES = 12   !Maximum number of impropers in one residue

#ifdef HAVE_DANNY
  real(dp), parameter, private :: Danny_R_q = 2.0_dp
  real(dp), parameter, private :: Danny_Delta_q = 0.1_dp

  real(dp), parameter, private :: Danny_Si_Si_cutoff = 2.8_dp
  real(dp), parameter, private :: Danny_Si_Si_O_cutoff = 2.8_dp
  real(dp), parameter, private :: Danny_Si_O_cutoff = 2.6_dp
  real(dp), parameter, private :: Danny_Si_H_cutoff = 0._dp
!  real(dp), parameter, private :: Danny_O_O_cutoff = 2.6_dp
  real(dp), parameter, private :: Danny_O_O_cutoff = 0._dp
  real(dp), parameter, private :: Danny_O_H_cutoff = 1.0_dp
  real(dp), parameter, private :: Danny_H_H_cutoff = 0._dp
#endif

contains


  !Analogous to Steve's create_AMBER_input, could be used mutually if AMBER_instance and param_cp2k were merged into 1 parameter object
  subroutine create_CHARMM(at,do_CHARMM,intrares_impropers)

    type(Atoms),           intent(inout) :: at
    logical,     optional, intent(in)    :: do_CHARMM
    type(Table), optional, intent(out)   :: intrares_impropers

    type(Inoutput)                       :: lib
    character(4)                         :: cha_res_name(MAX_KNOWN_RESIDUES), Cres_name
    character(3)                         :: pdb_res_name(MAX_KNOWN_RESIDUES), pres_name
    integer                              :: residue_number(at%N)
    character(4)                         :: atom_name(at%N)
    real(dp)                             :: atom_charge(at%N)
    type(Table)                          :: residue_type, list
    logical                              :: unidentified(at%N)
    integer, allocatable, dimension(:,:) :: motif
    integer                              :: i, m, n, nres
    character(4), allocatable, dimension(:) :: at_names
    real(dp),     allocatable, dimension(:) :: at_charges
    logical                              :: my_do_charmm
    integer                              :: atom_type_index, &
                                            atom_res_name_index, &
                                            atom_mol_name_index, &
                                            atom_res_number_index, &
                                            atom_charge_index
    logical                              :: ex
    character(len=value_len)             :: residue_library
    integer                              :: i_impr, n_impr
    integer, allocatable                 :: imp_atoms(:,:)
    real(dp)                             :: mol_charge_sum
    logical                              :: found_residues
#ifdef HAVE_DANNY
    type(Table)                          :: atom_Si, atom_SiO, SiO_list
    real(dp), dimension(:), allocatable  :: charge
integer :: j,k, atom_i
logical :: silanol
    type(Table) :: bondH,bondSi
    integer :: bond_H,bond_Si
#endif
!    integer                             :: qm_flag_index, pos_indices(3)
!    logical                             :: do_qmmm

    call system_timer('create_CHARMM')

    my_do_charmm = .true.
    if (present(do_CHARMM)) my_do_charmm = do_CHARMM

    residue_library = ''
    call print_title('Creating CHARMM format')
    ex = .false.
    ex = get_value(at%params,'Library',residue_library)
    if (ex) call print('Library: '//trim(residue_library))
    if (.not.ex) call system_abort('create_CHARMM: no residue library specified, but topology generation requested')

    !Open the residue library
    !call print('Opening library...')
    call initialise(lib,trim(residue_library),action=INPUT)

    !Set all atoms as initially unidentified
    unidentified = .true.

    !Read each of the residue motifs from the library
    n = 0
    nres = 0
    mol_charge_sum = 0._dp
    found_residues = .false.
    if (present(intrares_impropers)) call initialise(intrares_impropers,4,0,0,0,0)
    call allocate(residue_type,1,0,0,0,1000)
    call print('Identifying atoms...')
    do 

       ! Pull the next residue template from the library
       if (my_do_charmm) then
          call next_motif(lib,cres_name,pres_name,motif,atom_names=at_names,atom_charges=at_charges,n_impr=n_impr,imp_atoms=imp_atoms,do_CHARMM=.true.)
       else
          call next_motif(lib,cres_name,pres_name,motif,atom_names=at_names,do_CHARMM=.false.)
       endif

       if (cres_name=='NONE') then
          found_residues = .true.
          exit
       endif

       ! Store its CHARMM (3 char) and PDB (3 char) names
       ! e.g. cha/pdb_res_name(5) corresponds to the 5th residue found in the library
       n = n + 1
       cha_res_name(n) = cres_name
       pdb_res_name(n) = pres_name

       ! Search the atom structure for this residue
       call print('|-Looking for '//cres_name//'...')
       call find_motif(at,motif,list,mask=unidentified)

       if (list%N > 0) then
          
          call print('| |-Found '//list%N//' occurrences of '//cres_name)
          mol_charge_sum = mol_charge_sum + list%N * sum(at_charges(1:size(at_charges)))

          ! Loop over all found instances of the residue

          do m = 1, list%N

             !Mark the newly identified atoms
!1 row is 1 residue
             unidentified(list%int(:,m)) = .false.

             !Store the residue info
             nres = nres + 1
             call append(residue_type,(/n/))
             ! if residue_type%int(1,2) == 3 then residue no. 2 matches the 3rd residue in the library
             residue_number(list%int(:,m)) = nres
                  !e.g. if residue_number(i) = j        j-th residue in the atoms object (1 to 8000 in case of 8000 H2O)
                  !        residue_type(1,j)   = k        k-th residue in the library file, in order
                  !        cha_res_name(k)   = 'ALA'    name of the k-th residue in the library file
                  !then atom 'i' is in a residue 'ALA'
             atom_name(list%int(:,m)) = at_names
             if (my_do_charmm) then
                atom_charge(list%int(:,m)) = at_charges
               ! intraresidual IMPROPERs
                if (present(intrares_impropers)) then
                   do i_impr = 1, n_impr
                      call append(intrares_impropers,list%int(imp_atoms(1:4,i_impr),m))
!                      call print('Added intraresidual improper '//intrares_impropers%int(1:4,intrares_impropers%N))
                   enddo
                endif
             endif
          end do

       end if

       call print('|')

    end do

   ! check if residue library is empty
    if (.not.found_residues) call system_abort('Residue library '//trim(lib%filename)//' does not contain any residues!')

#ifdef HAVE_DANNY
!>>>>>>>>> DANNY POTENTIAL <<<<<<<<<!

   ! SIO residue for Danny potential if Si atom is present in the atoms structure
    if (any(at%Z(1:at%N).eq.14)) then
       call print('|-Looking for SIO residue, not from the library...')
       call print('| |-Found... will be treated as 1 molecule, 1 residue...')
       !all this bulk will be 1 residue
       n = n + 1
       cha_res_name(n) = 'SIO2'
       call append(residue_type,(/n/))
       nres = nres + 1

       !add Si (SIO) atoms
       call initialise(atom_Si,4,0,0,0,0)
       do i = 1,at%N
          if (at%Z(i).eq.14) then
!             call print('found Si atom '//atom_Si%int(1,i))
             call append(atom_Si,(/i,0,0,0/))
          endif
       enddo
       call print(atom_Si%N//' Si atoms found in total')
       !2 cluster carving steps, to include OSI and HSI atoms
       call bfs_step(at,atom_Si,atom_SiO,nneighb_only=.true.,min_images_only=.true.)
       call print(atom_SiO%N//' O atoms found in total')
       do i=1,atom_SiO%N
           if (at%Z(atom_SiO%int(1,i)).eq.1) then
              call print('WARNING! Si and H are very close')
              bond_H = atom_SiO%int(1,i)
              call initialise(bondH,4,0,0,0,0)
              call append(bondH,(/bond_H,0,0,0/))
              call bfs_step(at,bondH,bondSi,nneighb_only=.true.,min_images_only=.true.)
              do j = 1,bondSi%N
                 if (at%Z(bondSi%int(1,i)).eq.14) then
                    bond_Si = bondSi%int(1,i)
                    call print('WARNING! Remove Si '//bond_Si//' and H '//bond_H//' bond ('//distance_min_image(at,bond_H,bond_Si)//')')
                    call delete_bond(at,bond_H,bond_Si)
                 endif
              enddo
           endif
!          call print('atom_SiO has '//at%Z(atom_SiO%int(1,i)))
       enddo
!       if (any(at%Z(atom_SiO%int(1,1:atom_SiO%N)).eq.1)) call system_abort('Si-H bond')
   !    call bfs_step(at,atom_SiO,atom_SIOH,nneighb_only=.true.,min_images_only=.true.)
       call add_cut_hydrogens(at,atom_SiO)
       call print(atom_SiO%N//' O/H atoms found in total')
       !check if none of these atoms are identified yet
       if (any(.not.unidentified(atom_Si%int(1,1:atom_Si%N)))) then
          call system_abort('already identified atoms found again.')
       endif
       if (any(.not.unidentified(atom_SiO%int(1,1:atom_SiO%N)))) then
!          call system_abort('already identified atoms found again.')
          do i = 1,atom_SiO%N,-1
             if (.not.unidentified(atom_SiO%int(1,i))) then
                call print('delete from SiO2 list already identified atom '//atom_SiO%int(1,1:atom_SiO%N))
                call delete(atom_SiO,i)
             endif
          enddo
       endif
       unidentified(atom_Si%int(1,1:atom_Si%N)) = .false.
       unidentified(atom_SiO%int(1,1:atom_SiO%N)) = .false.

       !add atom, residue and molecule names
       do i = 1, atom_Si%N                              !atom_Si  only has Si atoms
          atom_i = atom_Si%int(1,i)
          if ( any(at%Z(at%connect%neighbour1(atom_i)%t%int(1,1:at%connect%neighbour1(atom_i)%t%N)).eq.8) .or. &
               any(at%Z(at%connect%neighbour2(atom_i)%t%int(1,1:at%connect%neighbour2(atom_i)%t%N)).eq.8) ) then
             atom_name(atom_i) = 'SIO'
!             call print('Found SIO silica oxygen.'//atom_i)
          else
             atom_name(atom_i) = 'SIB'
!             call print('Found SIB bulk silicon.'//atom_i)
          endif
!if (atoms_n_neighbours(at,atom_i).ne.4) call system_abort('More than 4 neighbours of Si '//atom_i)
       enddo
       do i = 1, atom_SiO%N                             !atom_SiO only has O,H atoms
          atom_i = atom_SiO%int(1,i)
          if (at%Z(atom_i).eq.8) then
!             silanol = .false.
!             do k = 1, atoms_n_neighbours(at,atom_i)
!                j = atoms_neighbour(at,atom_i,k)
!                if (at%Z(j).eq.1) silanol = .true.
!             enddo
!             if (silanol) then
!                atom_name(atom_i) = 'OSI'
!                call print('Found OH silanol oxygen.'//atom_i)
!             else
!                atom_name(atom_i) = 'OSB'
!                call print('Found OB bridging oxygen.'//atom_i)
!             endif
             if ( any(at%Z(at%connect%neighbour1(atom_i)%t%int(1,1:at%connect%neighbour1(atom_i)%t%N)).eq.1) .or. &
                  any(at%Z(at%connect%neighbour2(atom_i)%t%int(1,1:at%connect%neighbour2(atom_i)%t%N)).eq.1) ) then
                atom_name(atom_i) = 'OSI'
!                call print('Found OH silanol oxygen.'//atom_SiO%int(1,i))
             else
                atom_name(atom_i) = 'OSB'
!                call print('Found OB bridging oxygen.'//atom_SiO%int(1,i))
             endif
!if (atoms_n_neighbours(at,atom_i).ne.2) call system_abort('More than 4 neighbours of Si '//atom_i)
          endif
          if (at%Z(atom_SiO%int(1,i)).eq.1)  atom_name(atom_SiO%int(1,i)) = 'HSI'
       enddo
!call print(at%connect)

       residue_number(atom_Si%int(1,1:atom_Si%N)) = nres
       residue_number(atom_SiO%int(1,1:atom_SiO%N)) = nres
!this should be fine, added later:       cha_res_name(atom_SiO%int(1,1:atom_SiO%N)) = 'SIO2'
       atom_charge(atom_Si%int(1,1:atom_Si%N)) = 0._dp
       atom_charge(atom_SiO%int(1,1:atom_SiO%N)) = 0._dp
   !calc charges, to compare with CP2K calc charges
!!!!
!!!!
!!!!
      ! collect the whole molecule
       call initialise(SiO_list,4,0,0,0,0)
       do i = 1, atom_Si%N
          call append (SiO_list,atom_Si%int(1:4,i))
       enddo
       do i = 1, atom_SiO%N
          call append (SiO_list,atom_SiO%int(1:4,i))
       enddo

      ! calc charges for the whole molecule
       call create_pos_dep_charges(at,SiO_list,charge,residue_names=cha_res_name(residue_type%int(1,residue_number(1:at%N))))

      ! add charges to the CHARMM charges
       atom_charge(SiO_list%int(1,1:SiO_list%N)) = charge(SiO_list%int(1,1:SiO_list%N))
     ! do i=1,at%N
     !    call print('atom '//i//' has charge '//atom_charge(i))
     ! enddo
!!!!
!!!!
!!!!
       call finalise(atom_Si)
       call finalise(atom_SiO)
       call finalise(SiO_list)
    endif

#endif

    call print('Finished.')
    call print(nres//' residues found in total')

    if (any(unidentified)) then
       call print(count(unidentified)//' unidentified atoms')
       call print(find(unidentified))
do i=1,at%N
   if (unidentified(i)) call print(ElementName(at%Z(i))//' atom '//i//' has avgpos: '//round(at%pos(1,i),5)//' '//round(at%pos(2,i),5)//' '//round(at%pos(3,i),5))
   if (unidentified(i)) call print(ElementName(at%Z(i))//' atom '//i//' has number of neighbours: '//atoms_n_neighbours(at,i))
enddo

       ! THIS IS WHERE THE CALCULATION OF NEW PARAMETERS SHOULD GO
      call system_abort('create_CH_or_AM_input: Unidentified atoms')

    else
       call print('All atoms identified')
       call print('Total charge of the molecule: '//round(mol_charge_sum,5))
    end if

   ! add data to store CHARMM topology
    call add_property(at,'atom_type',repeat(' ',TABLE_STRING_LENGTH))
    call add_property(at,'atom_res_name',repeat(' ',TABLE_STRING_LENGTH))
    call add_property(at,'atom_mol_name',repeat(' ',TABLE_STRING_LENGTH))
    call add_property(at,'atom_res_number',0)
    call add_property(at,'atom_charge',0._dp)

    atom_type_index = get_property(at,'atom_type')
    atom_res_name_index = get_property(at,'atom_res_name')
    atom_mol_name_index = get_property(at,'atom_mol_name')
    atom_res_number_index = get_property(at,'atom_res_number')
    atom_charge_index = get_property(at,'atom_charge')

    at%data%str(atom_type_index,1:at%N) = 'X'
    at%data%str(atom_res_name_index,1:at%N) = 'X'
    at%data%str(atom_mol_name_index,1:at%N) = 'X'
    at%data%int(atom_res_number_index,1:at%N) = 0
    at%data%real(atom_charge_index,1:at%N) = 0._dp

    at%data%str(atom_res_name_index,1:at%N) = cha_res_name(residue_type%int(1,residue_number(1:at%N)))
    at%data%int(atom_res_number_index,1:at%N) = residue_number(1:at%N)
    at%data%str(atom_type_index,1:at%N) = atom_name(1:at%N)
    at%data%str(atom_type_index,1:at%N) = adjustl(at%data%str(atom_type_index,1:at%N))
!
!    do_qmmm = .true.
!    if (get_value(at%properties,trim('QM_flag'),pos_indices)) then
!       qm_flag_index = pos_indices(2)
!       call print('QM core atoms are treated as isolated atoms.')
!    else
!       do_qmmm = .false.
!    end if
!
    if (my_do_charmm) then
       do i = 1, at%N
!set mol_name to res_name, if the residue is a molecule
          if (any(trim(at%data%str(atom_res_name_index,i)).eq.(/'MCL','SOD','CLA','CES','POT','Rb+','CAL','MEF','FLA','TIP'/))) then
!          if (any(trim(at%data%str(atom_res_name_index,i)).eq.(/'MCL','SOD','CLA','CES','POT','Rb+','CAL','MEF','FLA','HYD','HWP','H3O'/))) then
             at%data%str(atom_mol_name_index,i) = at%data%str(atom_res_name_index,i)
          endif
#ifdef HAVE_DANNY
          if (any(trim(at%data%str(atom_res_name_index,i)).eq.(/'FLEX','TIP3','SIO2'/)).or. &
                 (trim(at%data%str(atom_res_name_index,i)).eq.'TIP')) then
#else
          if (any(trim(at%data%str(atom_res_name_index,i)).eq.(/'FLEX','TIP3'/)).or. &
                 (trim(at%data%str(atom_res_name_index,i)).eq.'TIP')) then
#endif
             at%data%str(atom_mol_name_index,i) = at%data%str(atom_res_name_index,i)
          endif
          if (any(trim(at%data%str(atom_res_name_index,i)).eq.(/'MG','ZN'/))) then
             at%data%str(atom_mol_name_index,i) = at%data%str(atom_res_name_index,i)
          endif
!set both mol_name and res_name to atom_type for QM core atoms.
!          if (do_qmmm) then
!             if (at%data%int(qm_flag_index,i).eq.1) then
!     call print('atom '//i//' has atom_type '//at%data%str(atom_type_index,i))
!                at%data%str(atom_mol_name_index,i) = at%data%str(atom_type_index,i)
!                at%data%str(atom_res_name_index,i) = at%data%str(atom_type_index,i)
!     call print('atom '//i//' has mol_name '//at%data%str(atom_mol_name_index,i))
!     call print('atom '//i//' has res_name '//at%data%str(atom_res_name_index,i))
!             endif
!          endif
       enddo
       at%data%real(atom_charge_index,1:at%N) = atom_charge(1:at%N)
    endif

    if (any(at%data%int(atom_res_number_index,1:at%N).le.0)) &
       call system_abort('create_CHARMM: atom_res_number is not >0 for every atom')
    if (any(at%data%str(atom_type_index,1:at%N).eq.'X')) &
       call system_abort('create_CHARMM: atom_type is not saved for at least one atom')
    if (any(at%data%str(atom_res_name_index,1:at%N).eq.'X')) &
       call system_abort('create_CHARMM: atom_res_name is not saved for at least one atom')

    !Free up allocations
    call finalise(residue_type)
    call finalise(list)
    if (allocated(motif)) deallocate(motif)

    !Close the library
    call finalise(lib)

    call system_timer('create_CHARMM')

  end subroutine create_CHARMM

  !Used by create_CHARMM, can read also from AMBER residue library
  !Can be used as Steve's next_motif, if do_CHARMM=.false. specified
  !do_CHARMM=.true. is the default
  subroutine next_motif(library,res_name,pdb_name,motif,atom_names,atom_charges,n_impr,imp_atoms,do_CHARMM)
    
    type(Inoutput),                   intent(in)  :: library
    character(4),                     intent(out) :: res_name
    character(3),                     intent(out) :: pdb_name
    integer,             allocatable, intent(out) :: motif(:,:)
    character(4),        allocatable, intent(out) :: atom_names(:)
    real(dp), optional,  allocatable, intent(out) :: atom_charges(:)
    logical,  optional,               intent(in)  :: do_CHARMM
    integer,  optional,  allocatable, intent(out) :: imp_atoms(:,:)
    integer,  optional,               intent(out) :: n_impr

    character(20), dimension(10) :: fields
    integer                      :: status, num_fields, data(7), i, n_at, max_num_fields
    type(Table)                  :: motif_table
    character(4)                 :: tmp_at_names(MAX_ATOMS_PER_RES)
    real(dp)                     :: tmp_at_charges(MAX_ATOMS_PER_RES),check_charge
    logical                      :: my_do_charmm
    character(len=1024)          :: line
   ! for improper generation
    integer                      :: imp_fields, tmp_imp_atoms(4,MAX_IMPROPERS_PER_RES)

    my_do_charmm = .true.
    if (present(do_CHARMM)) my_do_charmm = do_CHARMM

    if (my_do_charmm) then
       max_num_fields = 9
       imp_fields = 5
    else !do AMBER
       max_num_fields = 8
    endif

    status = 0

    do while(status==0)
       line = read_line(library,status)
       if (line(1:8)=='%residue') exit
    end do
    
    if (status/=0) then
       res_name = 'NONE'
       pdb_name = 'NON'
       return
    end if

    call parse_string(line,' ',fields,num_fields)
    res_name = trim(adjustl(fields(3)))
    pdb_name = trim(adjustl(fields(4)))

    call allocate(motif_table,7,0,0,0,20)
    n_at = 0
    check_charge=0._dp
   ! residue structure [& charges]
    do
       call parse_line(library,' ',fields,num_fields)
       if (num_fields < max_num_fields) exit
       do i = 1, 7
          data(i) = string_to_int(fields(i))
       end do
       call append(motif_table,data)
       n_at = n_at + 1
       tmp_at_names(n_at) = fields(8)
       if (my_do_charmm) then
          tmp_at_charges(n_at) = string_to_real(fields(9))
          check_charge=check_charge+tmp_at_charges(n_at)
       endif
    end do
    if (my_do_charmm) then
      ! intra amino acid IMPROPER generation here
       n_impr = 0
       do
          if (num_fields < imp_fields) exit
          if (trim(fields(1)).ne.'IMP') call system_abort('wrong improper format, should be: "IMP 1 4 7 10" with the 1st in the middle')
          n_impr = n_impr + 1
          do i = 1,4
             tmp_imp_atoms(i,n_impr) = string_to_int(fields(i+1))
          enddo
          call parse_line(library,' ',fields,num_fields)
       enddo
    endif

!    if (abs(mod(check_charge,1.0_dp)).ge.0.0001_dp .and. &
!        abs(mod(check_charge,1.0_dp)+1._dp).ge.0.0001_dp .and. &    !for -0.9999...
!        abs(mod(check_charge,1.0_dp)-1._dp).ge.0.0001_dp) then    !for +0.9999...
!       call print('WARNING next_motif: Charge of '//res_name//' residue is :'//round(check_charge,4))
!    endif

    allocate(motif(motif_table%N,7))

    motif = transpose(int_part(motif_table))

    allocate(atom_names(n_at))
    atom_names = tmp_at_names(1:n_at)

    if (my_do_charmm) then
       allocate(atom_charges(n_at))
       atom_charges = tmp_at_charges(1:n_at)
       allocate(imp_atoms(4,n_impr))
       imp_atoms(1:4,1:n_impr) = tmp_imp_atoms(1:4,1:n_impr)
    endif

    call finalise(motif_table)
    
  end subroutine next_motif

  !writes Brookhaven PDB format
  !charges are printed into the PSF file, too
  !use CHARGE_EXTENDED keyword i.e. reads charges from the last column of PDB file 
  !ATOM      1  CT3 ALA A   1       0.767   0.801  13.311  0.00  0.00     ALA   C  -0.2700
  !ATOM      2   HA ALA A   1       0.074  -0.060  13.188  0.00  0.00     ALA   H   0.0900
  !ATOM      3   HA ALA A   1       0.176   1.741  13.298  0.00  0.00     ALA   H   0.0900
  subroutine write_brookhaven_pdb_file(at,pdb_file,run_type)

    character(len=*),  intent(in)  :: pdb_file
    type(atoms),       intent(in)  :: at
    integer, optional, intent(in)  :: run_type


!    character(*), parameter  :: pdb_format = '(a6,i5,1x,a4,1x,a4,1x,i4,1x,3x,3f8.3,2f6.2,10x,a2,2x,f7.4)'
    character(*), parameter  :: pdb_format = '(a6,i5,1x,a4,1x,a4,i5,1x,3x,3f8.3,2f6.2,5x,a4,2x,a2,2x,f7.4)'
    type(Inoutput)           :: pdb
    character(88)            :: sor
    integer                  :: mm
    character(4)             :: QM_prefix_atom_mol_name
    integer                  :: qm_flag_index, &
                                atom_type_index, &
                                atom_res_name_index, &
                                atom_mol_name_index, &
                                atom_res_number_index, &
                                atom_charge_index
    integer                  :: my_run_type

  !Brookhaven PDB format
  !       sor(1:6)   = 'ATOM  '
  !       sor(7:11)  = mm
  !       sor(13:16) = this%atom_type(mm)
  !       sor(18:21) = this%res_name(mm)
  !!      sor(22:22) = ' A'                   !these two are now
  !       sor(23:26) = residue_number(mm)     !   merged to handle >9999 residues
  !       sor(31:38) = at%pos(1,mm)
  !       sor(39:46) = at%pos(2,mm)
  !       sor(47:54) = at%pos(3,mm)
  !       sor(55:60) = '  0.00'
  !       sor(61:66) = '  0.00'
  !!      sor(72:75) = 'MOL1'
  !       sor(77:78) = ElementName(at%Z(mm))
  !       sor(79:86) = this%atom_charge(mm)

    call system_timer('write_brookhaven_pdb_file')

    my_run_type = optional_default(MM_RUN,run_type)

    call initialise(pdb,trim(pdb_file),action=OUTPUT)
    call print('   PDB file: '//trim(pdb%filename))
!    call print('REMARK'//at%N,file=pdb)
!lattice information could be added in a line like this:
!CRYST1    1.000    1.000    1.000  90.00  90.00  90.00 P 1           1          

    if (any(my_run_type.eq.(/QMMM_RUN_CORE,QMMM_RUN_EXTENDED/))) then
       qm_flag_index = get_property(at,'QM_flag')
    endif
    atom_type_index = get_property(at,'atom_type')
    atom_res_name_index = get_property(at,'atom_res_name')
    atom_mol_name_index = get_property(at,'atom_mol_name')
    atom_res_number_index = get_property(at,'atom_res_number')
    atom_charge_index = get_property(at,'atom_charge')

    do mm=1,at%N
      ! e.g. CP2K needs different name for QM molecules, if use isolated atoms
       sor = ''
       QM_prefix_atom_mol_name = ''
       QM_prefix_atom_mol_name = trim(at%data%str(atom_mol_name_index,mm))
       if (any(my_run_type.eq.(/QMMM_RUN_CORE,QMMM_RUN_EXTENDED/))) then
          if (at%data%int(qm_flag_index,mm).ge.QMMM_RUN_CORE .and. at%data%int(qm_flag_index,mm).le.my_run_type) then
             QM_prefix_atom_mol_name = 'QM'//trim(at%data%str(atom_mol_name_index,mm))
!             call print('QM molecule '//QM_prefix_atom_mol_name)
          endif
       endif
!             call print('molecule '//QM_prefix_atom_mol_name)
!       call print('writing PDB file: atom type '//at%data%str(atom_type_index,mm))
       write(sor,pdb_format) 'ATOM  ',mm,at%data%str(atom_type_index,mm),at%data%str(atom_res_name_index,mm),at%data%int(atom_res_number_index,mm), &
                             at%pos(1:3,mm),0._dp,0._dp,QM_prefix_atom_mol_name,ElementName(at%Z(mm)),at%data%real(atom_charge_index,mm)
!                             at%pos(1:3,mm),0._dp,0._dp,this%atom_res_name(mm),ElementName(at%Z(mm)),this%atom_charge(mm)
       call print(sor,file=pdb)
    enddo
    call print('END',file=pdb)

    call finalise(pdb)

    call system_timer('write_brookhaven_pdb_file')

  end subroutine write_brookhaven_pdb_file

  subroutine write_psf_file(at,psf_file,run_type,intrares_impropers,imp_filename)

    character(len=*),        intent(in) :: psf_file
    type(atoms),             intent(in) :: at
    integer,                 intent(in) :: run_type
    type(Table),   optional, intent(in) :: intrares_impropers
    character(80), optional, intent(in) :: imp_filename

    type(Inoutput)          :: psf
    character(103)          :: sor
    character(*), parameter :: psf_format = '(I8,1X,A4,I5,1X,A4,1X,A4,1X,A4,1X,2G14.6,I8)'
    character(*), parameter :: title_format = '(I8,1X,A)'
    character(*), parameter :: int_format = 'I8'
    integer                 :: mm, i
    character(4)            :: QM_prefix_atom_mol_name
    integer                 :: qm_flag_index, &
                               atom_type_index, &
                               atom_res_name_index, &
                               atom_mol_name_index, &
                               atom_res_number_index, &
                               atom_charge_index
    type(Table)             :: bonds
    type(Table)             :: angles
    type(Table)             :: dihedrals, impropers

    call system_timer('write_psf_file')

    !intraresidual impropers: table or read in from file
    if (.not.present(intrares_impropers).and..not.present(imp_filename)) call print('WARNING!!! NO INTRARESIDUAL IMPROPERS USED!')
    if (present(imp_filename)) then
       call system_abort('Not yet implemented.')
    endif

    if (any(run_type.eq.(/QMMM_RUN_CORE,QMMM_RUN_EXTENDED/))) then
       qm_flag_index = get_property(at,'QM_flag')
    endif
    atom_type_index = get_property(at,'atom_type')
    atom_res_name_index = get_property(at,'atom_res_name')
    atom_mol_name_index = get_property(at,'atom_mol_name')
    atom_res_number_index = get_property(at,'atom_res_number')
    atom_charge_index = get_property(at,'atom_charge')
    call initialise(psf,trim(psf_file),action=OUTPUT)
    call print('   PSF file: '//trim(psf%filename))

    call print('PSF',file=psf)
    call print('',file=psf)

    write(sor,title_format) 1,'!NTITLE'
    call print(sor,file=psf)
    write(sor,'(A)') '  PSF file generated by libAtoms -- http://www.libatoms.org'
    call print(sor,file=psf)
    call print('',file=psf)

   ! ATOM section
    write(sor,title_format) at%N, '!NATOM'
    call print(sor,file=psf)
    do mm=1,at%N
       QM_prefix_atom_mol_name = ''
       QM_prefix_atom_mol_name = trim(at%data%str(atom_mol_name_index,mm))
       if (any(run_type.eq.(/QMMM_RUN_CORE,QMMM_RUN_EXTENDED/))) then
          if (at%data%int(qm_flag_index,mm).gt.0 .and. at%data%int(qm_flag_index,mm).le.run_type) then
             QM_prefix_atom_mol_name = 'QM'//trim(at%data%str(atom_mol_name_index,mm))
!             call print('QM molecule '//QM_prefix_atom_mol_name)
          endif
       endif
!       call print('molecule '//QM_prefix_atom_mol_name)
!       call print('writing PSF file: atom type '//at%data%str(atom_type_index,mm))
       write(sor,psf_format) mm, QM_prefix_atom_mol_name, at%data%int(atom_res_number_index,mm), &
                     at%data%str(atom_res_name_index,mm),at%data%str(atom_type_index,mm),at%data%str(atom_type_index,mm), &
                     at%data%real(atom_charge_index,mm),ElementMass(at%Z(mm))/MASSCONVERT,0
       call print(sor,file=psf)
    enddo
    call print('',file=psf)

   ! BOND section
    call create_bond_list(at,bonds)
    if (any(bonds%int(1:2,1:bonds%N).le.0) .or. any(bonds%int(1:2,1:bonds%N).gt.at%N)) &
       call system_abort('write_psf_file: element(s) of bonds not within (0;at%N]')
    call write_psf_section(data_table=bonds,psf=psf,section='BOND',int_format=int_format,title_format=title_format)

   ! ANGLE section
    call create_angle_list(at,bonds,angles)
    if (any(angles%int(1:3,1:angles%N).le.0) .or. any(angles%int(1:3,1:angles%N).gt.at%N)) then
       do i = 1, angles%N
          if (any(angles%int(1:3,i).le.0) .or. any(angles%int(1:3,i).gt.at%N)) &
          call print('angle: '//angles%int(1,i)//' -- '//angles%int(2,i)//' -- '//angles%int(3,i))
       enddo
       call system_abort('write_psf_file: element(s) of angles not within (0;at%N]')
    endif
    call write_psf_section(data_table=angles,psf=psf,section='THETA',int_format=int_format,title_format=title_format)

   ! DIHEDRAL section
    call create_dihedral_list(at,bonds,angles,dihedrals)
    if (any(dihedrals%int(1:4,1:dihedrals%N).le.0) .or. any(dihedrals%int(1:4,1:dihedrals%N).gt.at%N)) &
       call system_abort('write_psf_file: element(s) of dihedrals not within (0;at%N]')
    call write_psf_section(data_table=dihedrals,psf=psf,section='PHI',int_format=int_format,title_format=title_format)

   ! IMPROPER section
    call create_improper_list(at,angles,impropers,intrares_impropers=intrares_impropers)
    if (any(impropers%int(1:4,1:impropers%N).le.0) .or. any(impropers%int(1:4,1:impropers%N).gt.at%N)) &
       call system_abort('write_psf_file: element(s) of impropers not within (0;at%N]')
    call write_psf_section(data_table=impropers,psf=psf,section='IMPHI',int_format=int_format,title_format=title_format)

   !empty DON, ACC and NNB sections
    write(sor,title_format) 0,'!NDON'
    call print(sor,file=psf)
    call print('',file=psf)

    write(sor,title_format) 0,'!NACC'
    call print(sor,file=psf)
    call print('',file=psf)

    write(sor,title_format) 0,'!NNB'
    call print(sor,file=psf)
    call print('',file=psf)

    call print('END',file=psf)

    call finalise(bonds)
    call finalise(angles)
    call finalise(dihedrals)
    call finalise(impropers)
    call finalise(psf)

    call system_timer('write_psf_file')

  end subroutine write_psf_file

  subroutine write_psf_section(data_table,psf,section,int_format,title_format)

    type(Table),      intent(in) :: data_table
    type(InOutput),   intent(in) :: psf
    character(len=*), intent(in) :: section
    character(*),     intent(in) :: int_format
    character(*),     intent(in) :: title_format

    character(len=103)           :: sor
    integer                      :: mm, i, num_per_line

    if (.not.any(size(data_table%int,1).eq.(/2,3,4/))) &
       call system_abort('data table to print into psf file has wrong number of integers '//size(data_table%int,1))
    if (size(data_table%int,1).eq.2) num_per_line = 4
    if (size(data_table%int,1).eq.3) num_per_line = 3
    if (size(data_table%int,1).eq.4) num_per_line = 2

    sor = ''
    write(sor,title_format) data_table%N, '!N'//trim(section)
    call print(sor,file=psf)

    mm = 1
    do while (mm.le.(data_table%N-num_per_line+1-mod(data_table%N,num_per_line)))
       select case(size(data_table%int,1))
         case(2)
           write(sor,'(8'//trim(int_format)//')') &
              data_table%int(1,mm),   data_table%int(2,mm), &
              data_table%int(1,mm+1), data_table%int(2,mm+1), &
              data_table%int(1,mm+2), data_table%int(2,mm+2), &
              data_table%int(1,mm+3), data_table%int(2,mm+3)
           mm = mm + 4
         case(3)
           write(sor,'(9'//trim(int_format)//')') &
              data_table%int(1,mm),   data_table%int(2,mm),   data_table%int(3,mm), &
              data_table%int(1,mm+1), data_table%int(2,mm+1), data_table%int(3,mm+1), &
              data_table%int(1,mm+2), data_table%int(2,mm+2), data_table%int(3,mm+2)
           mm = mm + 3
         case(4)
           write(sor,'(8'//trim(int_format)//')') &
              data_table%int(1,mm),   data_table%int(2,mm),   data_table%int(3,mm), data_table%int(4,mm), &
              data_table%int(1,mm+1), data_table%int(2,mm+1), data_table%int(3,mm+1), data_table%int(4,mm+1)
           mm = mm + 2
       end select
       call print(sor,file=psf)
    enddo

   ! mm = data_table%N - mod(data_table%N,num_per_line) + 1
    sor = ''
    do i=1, mod(data_table%N,num_per_line) !if 0 then it does nothing
       select case(size(data_table%int,1))
         case(2)
           write(sor((i-1)*16+1:i*16),'(2'//trim(int_format)//')') data_table%int(1,mm), data_table%int(2,mm)
         case(3)
           write(sor((i-1)*24+1:i*24),'(3'//trim(int_format)//')') data_table%int(1,mm), data_table%int(2,mm), data_table%int(3,mm)
         case(4)
           write(sor((i-1)*32+1:i*32),'(4'//trim(int_format)//')') data_table%int(1,mm), data_table%int(2,mm), data_table%int(3,mm), data_table%int(4,mm)
       end select
       mm = mm + 1
    enddo

    if (mm .ne. data_table%N+1) call system_abort('psf writing: written '//(mm-1)//' of '//data_table%N)
    if (mod(data_table%N,num_per_line).ne.0) call print(sor,file=psf)
    call print('',file=psf)

  end subroutine write_psf_section

  subroutine create_bond_list(at,bonds)

  type(Atoms), intent(in)  :: at
  type(Table), intent(out) :: bonds

  type(Table) :: atom_a,atom_b
  integer     :: i,j
  integer     :: atom_j
!  logical              :: do_qmmm
!  integer,dimension(3) :: pos_indices
!  integer              :: qm_flag_index
  integer              :: atom_mol_name_index

    call system_timer('create_bond_list')

    if (.not. at%connect%initialised) &
       call system_abort('create_bond_list: connectivity not initialised, call calc_connect first')

#ifdef HAVE_DANNY
    atom_mol_name_index = get_property(at,'atom_mol_name')
#endif
    call initialise(bonds,2,0,0,0,0)

!    do_qmmm = .true.
!    if (get_value(at%properties,trim('QM_flag'),pos_indices)) then
!       qm_flag_index = pos_indices(2)
!    else
!       do_qmmm = .false.
!    end if
!
    do i=1,at%N
       call initialise(atom_a,4,0,0,0,0)
       call append(atom_a,(/i,0,0,0/))
#ifdef HAVE_DANNY
       call bfs_step(at,atom_a,atom_b,nneighb_only=.false.,min_images_only=.true.)
#else
       call bfs_step(at,atom_a,atom_b,nneighb_only=.true.,min_images_only=.true.)
#endif
       do j = 1,atom_b%N
          atom_j = atom_b%int(1,j)
          if (atom_j.gt.i) then
!      ! QM core atoms should be isolated atoms
!!call print('atom '//i//' (QM flag '//at%data%int(qm_flag_index,i)//')')
!!call print('atom '//atom_j//' (QM flag '//at%data%int(qm_flag_index,atom_j)//')')
!
!             if (do_qmmm) then
!                if (any((/at%data%int(qm_flag_index,i),at%data%int(qm_flag_index,atom_j)/).eq.1)) then
!!                   call print('not added '//i//' (QM flag '//at%data%int(qm_flag_index,i)//') -- '//atom_j//' (QM flag '//at%data%int(qm_flag_index,atom_j)//')')
!                   cycle
!                else
!!                   call print('added '//i//' (QM flag '//at%data%int(qm_flag_index,i)//') -- '//atom_j//' (QM flag '//at%data%int(qm_flag_index,atom_j)//')')
!                endif
!             endif
#ifdef HAVE_DANNY
            ! do not include H2O -- SiO2 bonds
             if ((trim(at%data%str(atom_mol_name_index,atom_j)).ne.trim(at%data%str(atom_mol_name_index,i)))) then
                call print ('Check if add '//atom_j//'--'//i//' from molecules '//trim(at%data%str(atom_mol_name_index,atom_j))//'--'//trim(at%data%str(atom_mol_name_index,i)))
             !call print('Check if add '//trim(at%data%str(atom_mol_name_index,atom_j))//'--'//trim(at%data%str(atom_mol_name_index,i)))
!                call print ('  Yes, if '//distance_min_image(at,atom_j,i)//' < '//(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(i)))*at%nneightol)
!                call print ((distance_min_image(at,atom_j,i).gt.(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(i)))*at%nneightol) )
!             call print(.not.( (trim(at%data%str(atom_mol_name_index,atom_j)).ne.trim(at%data%str(atom_mol_name_index,i))) .and. &
!                        (distance_min_image(at,atom_j,i).gt.(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(i)))*at%nneightol) ))
             endif
             if (.not.( (trim(at%data%str(atom_mol_name_index,atom_j)).ne.trim(at%data%str(atom_mol_name_index,i))) .and. &
                        (distance_min_image(at,atom_j,i).gt.(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(i)))*at%nneightol) )) &
#endif
             call append(bonds,(/i,atom_j/))
!             call print('added '//i//' -- '//atom_j)
          else
!             call print('not added '//i//' -- '//atom_j)
          endif
       enddo
       call finalise(atom_a)
       call finalise(atom_b)
    enddo

    if (any(bonds%int(1:2,1:bonds%N).le.0) .or. any(bonds%int(1:2,1:bonds%N).gt.at%N)) &
       call system_abort('create_bond_list: element(s) of bonds not within (0;at%N]')

    call system_timer('create_bond_list')

  end subroutine create_bond_list

  subroutine create_angle_list(at,bonds,angles)

  type(Atoms), intent(in)  :: at
  type(Table), intent(in)  :: bonds
  type(Table), intent(out) :: angles

  integer     :: i,j
  type(Table) :: atom_a, atom_b
  integer     :: atom_j
#ifdef HAVE_DANNY
  logical     :: keep_it
  integer     :: atom_type_index
  integer     :: atom_mol_name_index
#endif

    call system_timer('create_angle_list')

    if (.not. at%connect%initialised) &
       call system_abort('create_bond_list: connectivity not initialised, call calc_connect first')

#ifdef HAVE_DANNY
    atom_type_index = get_property(at,'atom_type')
    atom_mol_name_index = get_property(at,'atom_mol_name')
#endif
    call initialise(angles,3,0,0,0,0)

    do i=1,bonds%N
      ! look for one more to the beginning: ??--1--2 where ??<2
       call initialise(atom_a,4,0,0,0,0)
       call append(atom_a,(/bonds%int(1,i),0,0,0/))
#ifdef HAVE_DANNY
       call bfs_step(at,atom_a,atom_b,nneighb_only=.false.,min_images_only=.true.)
#else
       call bfs_step(at,atom_a,atom_b,nneighb_only=.true.,min_images_only=.true.)
#endif
       do j = 1,atom_b%N
          atom_j = atom_b%int(1,j)
#ifdef HAVE_DANNY
         ! we kept 2.8 A cutoff for Si-Si and Si-O: reduce it to 2.6 for Si-O-Si, O-Si-O, Si-O-H
          if (any(at%Z(atom_j)*1000000+at%Z(bonds%int(1,i))*1000+at%Z(bonds%int(2,i)).eq.(/14008014,8014008,14008001,1008014/))) then
             keep_it =  (distance_min_image(at,atom_j,bonds%int(1,i)).le.2.6_dp).and. &
                        (distance_min_image(at,bonds%int(2,i),bonds%int(1,i)).le.2.6_dp)
             !call print('keeping '//trim(at%data%str(atom_type_index,atom_j))//atom_j//'--'//trim(at%data%str(atom_type_index,bonds%int(1,i)))//bonds%int(1,i)//'--'//trim(at%data%str(atom_type_index,bonds%int(2,i)))//bonds%int(2,i)//' ? '//keep_it)
          else
             keep_it = .true.
          endif
         ! we still have a 2.6 A cutoff even for intermolecular Si-O. Decrease it to nearest neighbour tolerance
          if ( (trim(at%data%str(atom_mol_name_index,atom_j)).ne.trim(at%data%str(atom_mol_name_index,bonds%int(1,i)))) .and. &
               (distance_min_image(at,atom_j,bonds%int(1,i)).gt.(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(bonds%int(1,i))))*at%nneightol) ) &
             keep_it = .false.

          if (keep_it.and.(atom_j.lt.bonds%int(2,i))) &
#else
          if (atom_j.lt.bonds%int(2,i)) &
#endif
             call append(angles,(/atom_j,bonds%int(1,i),bonds%int(2,i)/))
       enddo
       call finalise(atom_a)
       call finalise(atom_b)
      ! look for one more to the end: 1--2--?? where 1<??
       call initialise(atom_a,4,0,0,0,0)
       call append(atom_a,(/bonds%int(2,i),0,0,0/))
#ifdef HAVE_DANNY
       call bfs_step(at,atom_a,atom_b,nneighb_only=.false.,min_images_only=.true.)
#else
       call bfs_step(at,atom_a,atom_b,nneighb_only=.true.,min_images_only=.true.)
#endif
       do j = 1,atom_b%N
          atom_j = atom_b%int(1,j)
#ifdef HAVE_DANNY
         ! we kept 2.8 A cutoff for Si-Si and Si-O: reduce it to 2.6 for Si-O-Si, O-Si-O, Si-O-H
          if (any(at%Z(atom_j)*1000000+at%Z(bonds%int(2,i))*1000+at%Z(bonds%int(1,i)).eq.(/14008014,8014008,14008001,1008014/))) then
             keep_it =  (distance_min_image(at,atom_j,bonds%int(2,i)).le.2.6_dp).and. &
                        (distance_min_image(at,bonds%int(2,i),bonds%int(1,i)).le.2.6_dp)
             !call print('keeping '//trim(at%data%str(atom_type_index,bonds%int(1,i)))//bonds%int(1,i)//'--'//trim(at%data%str(atom_type_index,bonds%int(2,i)))//bonds%int(2,i)//'--'//trim(at%data%str(atom_type_index,atom_j))//atom_j//' ? '//keep_it)
          else
             keep_it = .true.
          endif
         ! we still have a 2.6 A cutoff even for intermolecular Si-O. Decrease it to nearest neighbour tolerance
          if ( (trim(at%data%str(atom_mol_name_index,atom_j)).ne.trim(at%data%str(atom_mol_name_index,bonds%int(2,i)))) .and. &
               (distance_min_image(at,atom_j,bonds%int(2,i)).gt.(ElementCovRad(at%Z(atom_j))+ElementCovRad(at%Z(bonds%int(2,i))))*at%nneightol) ) &
             keep_it = .false.

          if (keep_it.and.(atom_j.lt.bonds%int(1,i))) &
#else
          if (atom_j.lt.bonds%int(1,i)) &
#endif
             call append(angles,(/bonds%int(1,i),bonds%int(2,i),atom_j/))
       enddo
       call finalise(atom_a)
       call finalise(atom_b)

    enddo

    if (any(angles%int(1:3,1:angles%N).le.0) .or. any(angles%int(1:3,1:angles%N).gt.at%N)) then
       do i = 1, angles%N
          if (any(angles%int(1:3,i).le.0) .or. any(angles%int(1:3,i).gt.at%N)) &
          call print('angle: '//angles%int(1,i)//' -- '//angles%int(2,i)//' -- '//angles%int(3,i))
       enddo
       call system_abort('create_angle_list: element(s) of angles not within (0;at%N]')
    endif

    call system_timer('create_angle_list')

  end subroutine create_angle_list

  subroutine create_dihedral_list(at,bonds,angles,dihedrals)

  type(Atoms), intent(in)  :: at
  type(Table), intent(in)  :: bonds
  type(Table), intent(in)  :: angles
  type(Table), intent(out) :: dihedrals

  integer     :: i,j
  type(Table) :: atom_a, atom_b
  integer     :: atom_j

    call system_timer('create_dihedral_list')

    if (.not. at%connect%initialised) &
       call system_abort('create_bond_list: connectivity not initialised, call calc_connect first')

    call initialise(dihedrals,4,0,0,0,0)

    do i=1,angles%N
#ifdef HAVE_DANNY
       if (any(at%Z(angles%int(1:3,i)).eq.14)) cycle
#endif
      ! look for one more to the beginning: ??--1--2--3
       call initialise(atom_a,4,0,0,0,0)
       call append(atom_a,(/angles%int(1,i),0,0,0/))
       call bfs_step(at,atom_a,atom_b,nneighb_only=.true.,min_images_only=.true.)
       do j = 1,atom_b%N
          atom_j = atom_b%int(1,j)
          if (atom_j.ne.angles%int(2,i)) then
            ! make sure it's not included twice -- no need to O(N^2) check at the end
             if (atom_j.lt.angles%int(3,i)) then
#ifdef HAVE_DANNY
                if (at%Z(atom_j).eq.14) cycle
#endif
                call append(dihedrals,(/atom_j,angles%int(1,i),angles%int(2,i),angles%int(3,i)/))
             endif
          endif
       enddo
       call finalise(atom_a)
       call finalise(atom_b)

      ! look for one more to the end: 1--2--3--??
       call initialise(atom_a,4,0,0,0,0)
       call append(atom_a,(/angles%int(3,i),0,0,0/))
       call bfs_step(at,atom_a,atom_b,nneighb_only=.true.,min_images_only=.true.)
       do j = 1,atom_b%N
          atom_j = atom_b%int(1,j)
          if (atom_j.ne.angles%int(2,i)) then
            ! make sure it's not included twice -- no need to O(N^2) check at the end
             if (atom_j.lt.angles%int(1,i)) then
#ifdef HAVE_DANNY
                if (at%Z(atom_j).eq.14) cycle
#endif
                call append(dihedrals,(/angles%int(1,i),angles%int(2,i),angles%int(3,i),atom_j/))
             endif
          endif
       enddo
       call finalise(atom_a)
       call finalise(atom_b)
    enddo

    if (any(dihedrals%int(1:4,1:dihedrals%N).le.0) .or. any(dihedrals%int(1:4,1:dihedrals%N).gt.at%N)) &
       call system_abort('create_dihedral_list: element(s) of dihedrals not within (0;at%N]')

    call system_timer('create_dihedral_list')

  end subroutine create_dihedral_list
  
  subroutine create_improper_list(at,angles,impropers,intrares_impropers)

  type(Atoms),           intent(in)  :: at
  type(Table),           intent(in)  :: angles
  type(Table),           intent(out) :: impropers
  type(Table), optional, intent(in)  :: intrares_impropers

  integer, dimension(4) :: imp_atoms
  integer               :: counter,nn,mm
  logical               :: cont
  integer, allocatable, dimension(:) :: count_array ! to count number of bonds
  integer               :: i,j, i_impr
  integer               :: last, tmp
  integer               :: atom_res_name_index
  integer               :: atom_type_index
  integer               :: i_pro, tmp_atoms(3)
  logical               :: reordered

    call system_timer('create_improper_list')

    if (.not. at%connect%initialised) &
       call system_abort('create_bond_list: connectivity not initialised, call calc_connect first')

    call initialise(impropers,4,0,0,0,0)

    allocate (count_array(angles%N))

    do i = 1,at%N
      if (.not.any(trim(at%species(i)).eq.(/'C','N'/))) cycle
      count_array = 0
      where (angles%int(2,1:angles%N).eq.i) count_array = 1
      if (sum(count_array(1:size(count_array))).ne.3) cycle
     ! only N with a neighbour that has 3 neighbors can stay
      if (trim(at%species(i)).eq.'N') then
         cont = .false.
         !for the first X1-N-X2
         nn = find_in_array(angles%int(2,1:angles%N),i)
           !check X1
            count_array = 0
            where (angles%int(2,1:angles%N).eq.angles%int(1,nn)) count_array = 1
            if (sum(count_array(1:size(count_array))).ne.3) cont = .true.
           !check X2
            count_array = 0
            where (angles%int(2,1:angles%N).eq.angles%int(3,nn)) count_array = 1
            if (sum(count_array(1:size(count_array))).ne.3) cont = .true.
         !for the second X1-N-X3
         mm = find_in_array(angles%int(2,nn+1:angles%N),i)
           !check X1
            count_array = 0
            where (angles%int(2,1:angles%N).eq.angles%int(1,nn+mm)) count_array = 1
            if (sum(count_array(1:size(count_array))).ne.3) cont = .true.
           !check X3
            count_array = 0
            where (angles%int(2,1:angles%N).eq.angles%int(3,nn+mm)) count_array = 1
            if (sum(count_array(1:size(count_array))).ne.3) cont = .true.
         !no need to check X2-N-X3
         if (.not.cont) cycle
      endif

     ! add to impropers i and its neighbours
      imp_atoms = 0
      imp_atoms(1) = i
      !neighbours from first angle
      nn = find_in_array(angles%int(2,1:angles%N),i)
        j = nn
        imp_atoms(2) = angles%int(1,j)
        imp_atoms(3) = angles%int(3,j)
      !3rd neighbour from second angle
      mm = find_in_array(angles%int(2,nn+1:angles%N),i)
        j = nn+mm
        if (.not.any(angles%int(1,j).eq.imp_atoms(1:3))) then
           imp_atoms(4) = angles%int(1,j)
        else
           imp_atoms(4) = angles%int(3,j)
        endif

!VVV ORDER is done according to the topology file! - and is read in when finding motifs
!if you don't do this, you won't have only the backbone impropers!
      atom_res_name_index = get_property(at,'atom_res_name')
      if (all(at%data%str(atom_res_name_index,imp_atoms(2:4)).eq.at%data%str(atom_res_name_index,imp_atoms(1)))) &
         cycle ! these should be added when identifying the residues
!ORDER: check charmm.pot file - start with $i, end with  H or O or N, in this order -- for intraresidual residues this can be needed later on...
      reordered = .true.
      tmp = 0
      ! if there is H
      last = find_in_array(at%Z(imp_atoms(2:4)),1)
      if (last.gt.0) then
        last = last + 1
        tmp = imp_atoms(4)
        imp_atoms(4) = imp_atoms(last)
        imp_atoms(last) = tmp
!        call print('reordered H to the end in '// &
!                    trim(ElementName(at%Z(imp_atoms(1))))//imp_atoms(1)//'--'// &
!                    trim(ElementName(at%Z(imp_atoms(2))))//imp_atoms(2)//'--'// &
!                    trim(ElementName(at%Z(imp_atoms(3))))//imp_atoms(3)//'--'// &
!                    trim(ElementName(at%Z(imp_atoms(4))))//imp_atoms(4))
      else
        last = find_in_array(at%Z(imp_atoms(2:4)),8) ! at the C-terminal there should be one "CC X X OC", with the double bonding the last one
        if (last.gt.0) then
          last = last + 1
          tmp = imp_atoms(4)
          imp_atoms(4) = imp_atoms(last)
          imp_atoms(last) = tmp
!          call print('reordered O to the end in '// &
!                      trim(ElementName(at%Z(imp_atoms(1))))//imp_atoms(1)//'--'// &
!                      trim(ElementName(at%Z(imp_atoms(2))))//imp_atoms(2)//'--'// &
!                      trim(ElementName(at%Z(imp_atoms(3))))//imp_atoms(3)//'--'// &
!                      trim(ElementName(at%Z(imp_atoms(4))))//imp_atoms(4))
        else
          last = find_in_array(at%Z(imp_atoms(2:4)),7)
          if (last.gt.0) then
            last = last + 1
            tmp = imp_atoms(4)
            imp_atoms(4) = imp_atoms(last)
            imp_atoms(last) = tmp
!            call print('reordered N to the end in '// &
!                        trim(ElementName(at%Z(imp_atoms(1))))//imp_atoms(1)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(2))))//imp_atoms(2)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(3))))//imp_atoms(3)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(4))))//imp_atoms(4))
          else
            reordered = .false.
!            call print('not reordered improper '// &
!                        trim(ElementName(at%Z(imp_atoms(1))))//imp_atoms(1)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(2))))//imp_atoms(2)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(3))))//imp_atoms(3)//'--'// &
!                        trim(ElementName(at%Z(imp_atoms(4))))//imp_atoms(4))
          endif
        endif
      endif

      !checking and adding only backbone (i.e. not intraresidual impropers) where the order of the 2nd and 3rd atoms doesn't matter
      atom_res_name_index = get_property(at,'atom_res_name')
      if (all(at%data%str(atom_res_name_index,imp_atoms(2:4)).eq.at%data%str(atom_res_name_index,imp_atoms(1)))) &
         cycle ! these should be added when identifying the residues

      if (.not.reordered) then
        ! Found N-C-CP1-CP3 Pro backbone, reordering according to atomic types (could be also according to the H neighbours)
!         call print('|PRO Found Pro backbone')
         atom_type_index = get_property(at,'atom_type')
         if (trim(at%data%str(atom_type_index,imp_atoms(1))).ne.'N') call system_abort('something has gone wrong. what is this if not proline? '// &
                     trim(at%data%str(atom_type_index,imp_atoms(1)))//imp_atoms(1)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(2)))//imp_atoms(2)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(3)))//imp_atoms(3)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(4)))//imp_atoms(4))
         tmp_atoms = 0
         do i_pro = 2,4
            if (trim(at%data%str(atom_type_index,imp_atoms(i_pro))).eq.'C')   tmp_atoms(1) = imp_atoms(i_pro)
            if (trim(at%data%str(atom_type_index,imp_atoms(i_pro))).eq.'CP1') tmp_atoms(2) = imp_atoms(i_pro)
            if (trim(at%data%str(atom_type_index,imp_atoms(i_pro))).eq.'CP3') tmp_atoms(3) = imp_atoms(i_pro)
         enddo
         if (any(tmp_atoms(1:3).eq.0)) call system_abort('something has gone wrong. what is this if not proline?'// &
                     trim(at%data%str(atom_type_index,imp_atoms(1)))//imp_atoms(1)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(2)))//imp_atoms(2)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(3)))//imp_atoms(3)//'--'// &
                     trim(at%data%str(atom_type_index,imp_atoms(4)))//imp_atoms(4))
         imp_atoms(2:4) = tmp_atoms(1:3)
!         call print('Reordered Pro improper '// &
!                     trim(at%data%str(atom_type_index,imp_atoms(1)))//imp_atoms(1)//'--'// &
!                     trim(at%data%str(atom_type_index,imp_atoms(2)))//imp_atoms(2)//'--'// &
!                     trim(at%data%str(atom_type_index,imp_atoms(3)))//imp_atoms(3)//'--'// &
!                     trim(at%data%str(atom_type_index,imp_atoms(4)))//imp_atoms(4))
      endif
      call append(impropers,imp_atoms(1:4))
!      call print('Added backbone improper '// &
!                  trim(ElementName(at%Z(imp_atoms(1))))//imp_atoms(1)//'--'// &
!                  trim(ElementName(at%Z(imp_atoms(2))))//imp_atoms(2)//'--'// &
!                  trim(ElementName(at%Z(imp_atoms(3))))//imp_atoms(3)//'--'// &
!                  trim(ElementName(at%Z(imp_atoms(4))))//imp_atoms(4))
    enddo

   ! add intraresidual impropers from the given Table
    if (present(intrares_impropers)) then
       do i_impr = 1, intrares_impropers%N
          call append(impropers,intrares_impropers%int(1:4,i_impr))
!          call print('Added intraresidual improper '// &
!                      trim(ElementName(at%Z(intrares_impropers%int(1,i_impr))))//intrares_impropers%int(1,i_impr)//'--'// &
!                      trim(ElementName(at%Z(intrares_impropers%int(2,i_impr))))//intrares_impropers%int(2,i_impr)//'--'// &
!                      trim(ElementName(at%Z(intrares_impropers%int(3,i_impr))))//intrares_impropers%int(3,i_impr)//'--'// &
!                      trim(ElementName(at%Z(intrares_impropers%int(4,i_impr))))//intrares_impropers%int(4,i_impr))
       enddo
    else
       call print('WARNING!!! NO INTRARESIDUAL IMPROPERS USED!!!')
    endif

   ! final check
    if (any(impropers%int(1:4,1:impropers%N).le.0) .or. any(impropers%int(1:4,1:impropers%N).gt.at%N)) &
       call system_abort('create_improper_list: element(s) of impropers not within (0;at%N]')

    call system_timer('create_improper_list')

  end subroutine create_improper_list

  function get_property(at,prop) result(prop_index)

    type(Atoms),      intent(in) :: at
    character(len=*), intent(in) :: prop
  
    integer,dimension(3) :: pos_indices
    integer              :: prop_index

    if (get_value(at%properties,trim(prop),pos_indices)) then
       prop_index = pos_indices(2)
    else
       call system_abort('get_property: No '//trim(prop)//' property assigned to the Atoms object!')
    end if

  end function get_property

#ifdef HAVE_DANNY
  subroutine create_pos_dep_charges(at,SiOH_list,charge,residue_names)

    type(Atoms), intent(in) :: at
    type(Table), intent(in) :: SiOH_list
    real(dp), allocatable, dimension(:), intent(out) :: charge
    character(4),dimension(:), intent(in) :: residue_names

    real(dp) :: r_ij(3), rij, fcq
    integer :: iatom, jatom, n_jatoms
    integer :: atom_i, atom_j, jj
    integer :: res_name_index

    if (size(residue_names).ne.at%N) call system_abort('Residue names have a different size '//size(residue_names)//'then the number of atoms '//at%N)
    allocate(charge(at%N))
    charge = 0._dp

    do iatom = 1, SiOH_list%N
       atom_i = SiOH_list%int(1,iatom)
       do jatom = 1, atoms_n_neighbours(at,atom_i)
          atom_j = atoms_neighbour(at, atom_i, jatom)
         ! check if atom_j is in SiOH_list
          if (.not.any(atom_j.eq.SiOH_list%int(1,1:SiOH_list%N))) then
             ! if it's a water O/H, ignore it!
             if (('TIP3'.eq.trim(residue_names(atom_j))) .or. &
                 ('TIP' .eq.trim(residue_names(atom_j)))) then
                 cycle
             else
                call print('Not found atom '//ElementName(at%Z(atom_j))//' '//atom_j//' in '//SiOH_list%int(1,1:SiOH_list%N))
                call system_abort('Found a neighbour that is not part of the SiO2 residue')
             endif
          endif
          if (atom_j.lt.atom_i) cycle

         ! get the distance between atom $i$ and $j$, apply (R_q + Delta_q) cutoff
          rij = distance_min_image(at, atom_i, atom_j)
          if (rij.gt.(Danny_R_q+Danny_Delta_q)) cycle

         !silanol endings (O--H and H--O)
          if (at%Z(atom_i).eq.1) then
             !call print('Found H--X for atoms '//atom_i//ElementName(at%Z(atom_i))//'--'//atom_j//ElementName(at%Z(atom_j)))
             if (rij.lt.1.0_dp) then
                charge(atom_i) = 0.2_dp
                charge(atom_j) = charge(atom_j) - 0.2_dp
             endif
          else
             if (at%Z(atom_j).eq.1) then
                !call print('Found X--H for atoms '//atom_i//ElementName(at%Z(atom_i))//'--'//atom_j//ElementName(at%Z(atom_j)))
                if (rij.lt.1.0_dp) then
                   charge(atom_i) = charge(atom_i) - 0.2_dp
                   charge(atom_j) = 0.2_dp
                endif
             else
            !Si--Si and O--O do not affect each other
                if (at%Z(atom_i).eq.at%Z(atom_j)) cycle
            !Si--O and O--Si
                fcq = calc_fc(rij)
                if (at%Z(atom_i).eq.14 .and. at%Z(atom_j).eq.8) then
                   !call print('Found Si--O for atoms '//atom_i//ElementName(at%Z(atom_i))//'--'//atom_j//ElementName(at%Z(atom_j)))
                   charge(atom_i) = charge(atom_i) + 0.4_dp * fcq
                   charge(atom_j) = charge(atom_j) - 0.4_dp * fcq
                else
                   if (at%Z(atom_i).eq.8 .and. at%Z(atom_j).eq.14) then
                      !call print('Found O--Si for atoms '//atom_i//ElementName(at%Z(atom_i))//'--'//atom_j//ElementName(at%Z(atom_j)))
                      charge(atom_i) = charge(atom_i) - 0.4_dp * fcq
                      charge(atom_j) = charge(atom_j) + 0.4_dp * fcq
                   else
                      print *, atom_i, ElementName(at%Z(atom_i)),'--', atom_j, ElementName(at%Z(atom_j)),' could not be located'
                      call system_abort('create_pos_dep_charge: unknown neighbour pair')
                   endif
                endif
             endif
          endif
       enddo
    enddo

!    print *, 'Calculated charge on atoms:'
!    do jj = 1, at%N
!       print *,'   atom ',jj,': ',charge(jj)
!    enddo


  end subroutine create_pos_dep_charges

! helper function
  function calc_fc(rij) result(fc)

    real(dp), intent(in) :: rij
    real(dp) :: fc

    real(dp) :: Danny_R, Danny_Delta

      Danny_R = Danny_R_q
      Danny_Delta = Danny_Delta_q

    if (rij.lt.(Danny_R-Danny_Delta)) then
       fc = 1._dp
    else
       if (rij.ge.(Danny_R+Danny_Delta)) then
          fc = 0._dp
       else
          fc = 1._dp - (rij - Danny_R + Danny_Delta) / (2._dp * Danny_Delta) + &
               sin(PI*(rij - Danny_R + Danny_Delta) / Danny_Delta) / (2._dp*PI)
       endif
    endif

  end function calc_fc

! code = 1000 * Z(atom_i) + Z(atom_j)
  function danny_cutoff(code) result(cutoff)

    integer, intent(in) :: code
    real(dp)            :: cutoff

    cutoff = 0._dp

    select case(code)
      case (14014)       !Si-Si
        cutoff = Danny_Si_Si_cutoff
      case (14008,8014) !Si-O
        cutoff = Danny_Si_Si_O_cutoff
      case (14001,1014)  !Si-H
        cutoff = Danny_Si_H_cutoff
      case (8008)       !O-O should never ever be less than 2.6
        cutoff = Danny_O_O_cutoff
      case (8001,1008)  !O-H
        cutoff = Danny_O_H_cutoff
      case (1001)        !H-H
        cutoff = Danny_H_H_cutoff
      case default
        call system_abort('danny_cutoff: unknown code '//code)
    end select

  end function danny_cutoff
#endif

   ! removes a bond between i and j, if the bond is present
  subroutine delete_bond(at, i, j)

    type(Atoms), intent(inout) :: at
    integer, intent(in) :: i, j

    integer :: ii, jj, kk, k, ll, change
    integer, allocatable :: bond_table(:,:)

    if (i.eq.j) return

    if (i.lt.j) then
       ii = i
       jj = j
    else
       ii = j
       jj = i
    endif

    allocate (bond_table(4,at%connect%neighbour1(ii)%t%N))
    bond_table = int_part(at%connect%neighbour1(ii)%t)
    kk = find_in_array(bond_table(1,:),jj)
    if (kk.gt.0) then
!       call print('found bond to delete for atoms '//ii//' '//jj)
       call delete(at%connect%neighbour1(ii)%t,kk)
    endif
    deallocate(bond_table)

   ! if I delete a bond from neighbour1, I should update in neighbour2 that
   ! it's the $(n-1)$-th (or the last is now takes the place of the deleted) neighbour from now on
    if (kk.gt.0) then
       do k = kk, at%connect%neighbour1(ii)%t%N     ! k-th neighbour of ii
          ll = at%connect%neighbour1(ii)%t%int(1,k)     ! is ll
          allocate (bond_table(2,at%connect%neighbour2(ll)%t%N))
          bond_table = int_part(at%connect%neighbour2(ll)%t)
          change = find_in_array(bond_table(1,:),ii)    ! ll has an account for ii
          if (change.eq.0) call system_abort('Found nonsymmetrical connectivity.')
          at%connect%neighbour2(ll)%t%int(2,change) = k ! this account is updated now
          deallocate (bond_table)
       enddo
    endif

    allocate (bond_table(2,at%connect%neighbour2(jj)%t%N))
    bond_table = int_part(at%connect%neighbour2(jj)%t)
    kk = find_in_array(bond_table(1,:),ii)
    if (kk.gt.0) then
!       call print('found bond to delete for atoms '//jj//' '//ii)
       call delete(at%connect%neighbour2(jj)%t,kk)
    endif
    deallocate(bond_table)

  end subroutine delete_bond

end module topology_module
