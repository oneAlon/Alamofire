//: Playground - noun: a place where people can play

import UIKit


class DataImport{
    var fileName = "test.txt"
}


class DataManager{
    lazy var importer = DataImport()
    var data = [String]()
    var testReadOnly : String{
        return "123"
    }
    var testReadWrite : String{
        set{
            self.testReadWrite = String(newValue)
        }
        get{
            return "123"
        }
    }
}

let dataM = DataManager()
dataM.data.append("zsss")

/// 这个时候DataImport才被创建
print(dataM.importer.fileName)

dataM.testReadOnly

//dataM.testReadWrite = "aaa"
//print(dataM.testReadWrite)

class Person{
    static var address = "天堂软件园"
    class var name: String{
        return "来付"
    }
}

class student: Person{
    override class var name: String{
        return "浙江来付"
    }
}

Person.name
student.name










