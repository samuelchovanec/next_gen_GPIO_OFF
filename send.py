import socket, random
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto('trigger:%d:f:gizmo.mp4,0,1,0,1,0,1,0,1' % random.randint(0, 2**32), ('192.168.1.64', 10000))
