import pychrono.fsi as fsi
# print([x for x in dir(fsi) if 'particle' in x or 'Particle' in x])
print([x for x in dir(fsi.MarkerPlanesVisibilityCallback) if not x.startswith('_')])