#!/usr/bin/python
#!/usr/bin/env python

from quippy import *
from quippy.surface import *
from quippy.elastic import *
import optparse

p = optparse.OptionParser(usage='%prog [options]')

p.add_option('-s', '--struct', action='store', help='Structure name (mandatory)')
p.add_option('-v', '--vol-per-atom', action='store', type='float', help='Volume per atom (default -1)', default=-1.0)
p.add_option('-V', '--vol-per-unit-cell', action='store', type='float', help='Volume per unit cell (default -1)', default=-1.0)
p.add_option('-r', '--repeat', action='store', help='Supercell repeat (default "1 1 1")', default='1 1 1')
p.add_option('-z', '--z-values', action='store', help='Atomic number values (1 per atom in primitive cell)')

p.add_option('--at-file', action='store', help='Input file for primitive unit cell')
p.add_option('--init-args', action='store', help='Potential init_args, e.g. {IP SW}')
p.add_option('--param-file', action='store', help='XML parameter filename')

p.add_option('--relax-lattice', action='store_true', help='Relax lattice of initial structure')
p.add_option('--cij-virial', action='store_true', help='Calculate elastic constants C_ij using virial')
p.add_option('--cij-fit', action='store_true', help='Calculate elastic constants C_ij using fitting')
p.add_option('--cij-symmetry', action='store', help='Symmetry name for C_ij fitting (default monoclinic)', default='monoclinic')

p.add_option('--surface-energy', action='store_true', help='Calculate surface energy')
p.add_option('--surface', action='store', help='Generate surface with given Miller indices (e.g. (111)[11b0])')
p.add_option('--relax-surface', action='store_true', help='Calculate relaxed surface energy')
p.add_option('--at-bulk', action='store', help='Input file for bulk cell')
p.add_option('--at-surface', action='store', help='Input file for surface cell')


opt, args = p.parse_args()

if len(args) != 0:
   p.error('No arguments are required')

if opt.repeat is not None:
    try:
        opt.repeat = [int(x) for x in opt.repeat.split()]
    except ValueError:
        p.error('Cannot parse repeat argument %s' % opt.repeat)

try:

    if opt.at_file is not None:
        at = Atoms(opt.at_file)
    else:
        at = structure_from_file(opt.struct, opt.vol_per_atom, opt.vol_per_unit_cell, opt.repeat, opt.z_values)

    pot = Potential(opt.init_args, param_filename=opt.param_file)

    at.set_cutoff(pot.cutoff()+1.0)
    at.calc_connect()

    if opt.relax_lattice:
        mainlog.prefix = 'LATTICE'        
        pot.minim(at, 'cg', 1e-6, 100, do_pos=False, do_lat=True)
        print 'Relaxed lattice / A'
        print at.lattice.round(3)
        print

    if opt.cij_virial:
        mainlog.prefix = 'CIJ_VIRIAL'
        c = fzeros((6,6))
        c0 = fzeros((6,6))
        pot.calc_elastic_constants(at, c=c, c0=c0)
        print 'C_ij (virial) / GPa ='
        print c.round(2)*GPA
        print 'C_ij^0 (virial) / GPa ='
        print c0.round(2)*GPA
        print
        
    if opt.cij_fit:
        mainlog.prefix = 'CIJ_FIT'        
        c = elastic_constants(pot, at, opt.cij_symmetry, relax=True)
        c0 = elastic_constants(pot, at, opt.cij_symmmetry, relax=False)
        print 'C_ij (fitted) / GPa ='
        print c.round(2)
        print 'C_ij^0 (fitted) / GPa ='
        print c0.round(2)
        print
        
    if opt.surface_energy:
        mainlog.prefix = 'SURFACE_ENERGY'        

        if opt.surface:
            axes = crack_parse_name(opt.surface)
            m = crack_rotation_matrix(at, axes[:,2], axes[:,3])
            bulk = orthorhombic_slab(at, rot=m, verbose=False)

            surface = bulk.copy()
            surface.lattice[2,2] = surface.lattice[2,2] + 10.0
            surface.set_lattice(surface.lattice, False)

        else:
            if not (opt.at_bulk and opt.at_surface):
                p.error('If --surface is not given, --at-bulk and --at-surface must both be present.')

            bulk = Atoms(opt.at_bulk)
            surface = Atoms(opt.at_surface)


        bulk.set_cutoff(pot.cutoff())
        bulk.calc_connect()
        surface.set_cutoff(pot.cutoff())
        surface.calc_connect()

        bulk.write('bulk.xyz')
        surface.write('surface.xyz')

        pot.calc(bulk, energy=True)

        if opt.relax_surface:
            pot.minim(surface, 'cg', 1e-6, 100, do_pos=True, do_lat=False)

        pot.calc(surface, energy=True)
        gamma = (surface.energy - bulk.energy)/(2.0*surface.lattice[1,1]*surface.lattice[3,3])*J_PER_M2
        print 'Surface energy: gamma = ', gamma, ' J/m^2'

except RuntimeError, re:
    p.error(str(re))


    

