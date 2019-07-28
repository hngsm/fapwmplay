#!py -2

import os
import sys
import httplib

class config(object):
    def __init__(self):
        self.address = "flashair"

fa = config()

def main(argv):
    command = argv[1]
    #print fa.address
    headers = {"Host": fa.address}
    if command == 'put' or command == 'run':
        try:
            filename = argv[2]
        except IndexError:
            filename = 'pwm.lua'
        try:
            path = argv[3]
            path = path.replace('C:/Program Files/Git', '')
        except IndexError:
            path = "pwm/pwm.lua"
        fileobj = open(filename, 'rb')
        h = httplib.HTTPConnection(fa.address)
        h.request('PUT', path, fileobj, headers)
        r = h.getresponse()
        print r.status
        #print r.read()
        if command == 'run':
            try:
                h.request('GET', path, headers=headers)
                #r = h.getresponse()
                #print r.status
                #print r.read()
            except:
                pass
    if command == 'kill':
        h = httplib.HTTPConnection(fa.address)
        h.request('GET', '/command.cgi?op=131&ADDR=0&LEN=1&DATA=2', headers=headers)
        r = h.getresponse()
        print r.status
        print r.read()

if __name__ == "__main__":
    sys.exit(main(sys.argv))
